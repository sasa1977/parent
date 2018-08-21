defmodule Parent.GenServerTest do
  use ExUnit.Case, async: true
  alias Parent.TestServer

  test "init" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)
    assert :sys.get_state(pid) == :initial_state
  end

  test "call" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

    assert TestServer.call(pid, fn state -> {{:response, state}, :new_state} end) ==
             {:response, :initial_state}

    assert :sys.get_state(pid) == :new_state
  end

  test "cast" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)
    assert TestServer.cast(pid, fn state -> {:updated_state, state} end) == :ok
    assert :sys.get_state(pid) == {:updated_state, :initial_state}
  end

  test "send" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)
    TestServer.send(pid, fn state -> {:updated_state, state} end)
    assert :sys.get_state(pid) == {:updated_state, :initial_state}
  end

  test "starting a child" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)
    child_id = make_ref()

    change =
      record_child_change(pid, child_id, fn ->
        meta = {child_id, :meta}
        child_spec = %{id: child_id, start: {Agent, :start_link, [fn -> nil end]}, meta: meta}

        res = Parent.GenServer.start_child(child_spec)
        assert {:ok, pid} = res
        assert Parent.GenServer.child_id(pid) == {:ok, child_id}
        assert Parent.GenServer.child_pid(child_id) == {:ok, pid}
        assert Parent.GenServer.child_meta(child_id) == {:ok, meta}
        res
      end)

    assert change.after.child? == true
    assert {:ok, child_pid} = change.result
    assert change.after.child_pid == {:ok, child_pid}
    assert change.after.num_children == change.before.num_children + 1

    child = Enum.find(change.after.children, fn {_id, pid, _meta} -> pid == child_pid end)
    assert {^child_id, ^child_pid, {^child_id, :meta}} = child
  end

  test "starting a child which times out" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

    %{id: child_id, pid: child_pid} =
      start_child(pid, %{
        start: {Agent, :start_link, [fn -> nil end]},
        timeout: 1
      })

    mref = Process.monitor(child_pid)
    assert_receive {:DOWN, ^mref, _, _, _reason}

    terminated_jobs = TestServer.call(pid, fn state -> {TestServer.terminated_jobs(), state} end)
    exit_info = Enum.find(terminated_jobs, &(&1.id == child_id))
    refute is_nil(exit_info)
    assert exit_info.reason == :timeout
  end

  test "stopping a child" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

    %{id: child_id, pid: child_pid, meta: meta} =
      start_child(pid, %{start: {Agent, :start_link, [fn -> nil end]}})

    mref = Process.monitor(child_pid)
    change = record_child_change(pid, child_id, fn -> Agent.stop(child_pid, :shutdown) end)

    assert_receive {:DOWN, ^mref, :process, ^child_pid, _reason}

    change =
      Map.merge(
        change,
        record_child_change(pid, child_id, fn -> nil end) |> Map.take([:after])
      )

    refute Process.alive?(child_pid)
    assert change.after.child? == false
    assert change.after.num_children == change.before.num_children - 1
    assert change.after.child_pid == :error
    child = Enum.find(change.after.children, fn {_id, pid, _meta} -> pid == child_pid end)
    assert child == nil

    terminated_info = Enum.find(change.after.terminated_jobs, &(&1.pid == child_pid))

    assert terminated_info == %{
             id: child_id,
             meta: meta,
             pid: child_pid,
             reason: :shutdown
           }
  end

  test "await_child_termination" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

    child = start_child(pid, %{start: {Task, :start_link, [fn -> :timer.sleep(100) end]}})

    change =
      record_child_change(pid, child.id, fn ->
        Parent.GenServer.await_child_termination(child.id, 1000)
      end)

    assert change.result == {child.pid, child.meta, :normal}

    refute Process.alive?(child.pid)
    assert change.after.child? == false
    assert change.after.num_children == change.before.num_children - 1
    assert change.after.child_pid == :error
    child = Enum.find(change.after.children, fn {_id, pid, _meta} -> pid == child.pid end)
    assert child == nil

    assert Enum.find(change.after.terminated_jobs, &(&1.pid == child.pid)) == nil
  end

  test "shutdown_all" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)
    Enum.each(1..100, &start_child(pid, %{id: &1, start: {Agent, :start_link, [fn -> :ok end]}}))
    change = record_child_change(pid, nil, fn -> Parent.GenServer.shutdown_all() end)

    assert change.after.num_children == 0
    Enum.each(change.before.children, fn {_id, pid, _meta} -> refute Process.alive?(pid) end)
  end

  test "update_meta" do
    {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

    %{id: child_id, meta: meta} =
      start_child(pid, %{start: {Task, :start_link, [fn -> :timer.sleep(100) end]}})

    TestServer.call(pid, fn state ->
      meta_updater = &{:updated, &1}
      assert :ok = Parent.GenServer.update_child_meta(child_id, meta_updater)
      assert Parent.GenServer.child_meta(child_id) == {:ok, meta_updater.(meta)}
      {:ok, state}
    end)
  end

  describe "supervisor" do
    test "which children" do
      {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

      child_specs =
        Enum.map(
          1..2,
          &start_child(pid, %{id: &1, start: {Agent, :start_link, [fn -> :ok end]}})
        )

      assert [child1, child2] = :supervisor.which_children(pid)
      assert {1, pid1, :worker, []} = child1
      assert Enum.find(child_specs, &(&1.id == 1)).pid == pid1

      assert {2, pid2, :worker, []} = child2
      assert Enum.find(child_specs, &(&1.id == 2)).pid == pid2
    end

    test "count children" do
      {:ok, pid} = TestServer.start_link(fn -> :initial_state end)

      Enum.map(
        1..2,
        &start_child(pid, %{id: &1, start: {Agent, :start_link, [fn -> :ok end]}})
      )

      assert :supervisor.count_children(pid) == [active: 2, specs: 2, supervisors: 0, workers: 2]
    end
  end

  defp record_child_change(pid, child_id, fun) do
    TestServer.call(pid, fn state ->
      before_info = parent_info(child_id)
      result = fun.()
      after_info = parent_info(child_id)

      response = %{
        before: before_info,
        after: after_info,
        result: result
      }

      {response, state}
    end)
  end

  defp parent_info(child_id) do
    %{
      children: Parent.GenServer.children(),
      terminated_jobs: TestServer.terminated_jobs(),
      num_children: Parent.GenServer.num_children(),
      child_pid: Parent.GenServer.child_pid(child_id),
      child?: Parent.GenServer.child?(child_id)
    }
  end

  defp start_child(parent_pid, child_spec) do
    id = Map.get(child_spec, :id, make_ref())
    child_spec = Map.merge(%{id: id, meta: {id, :meta}}, child_spec)

    TestServer.call(parent_pid, fn state ->
      {:ok, child_pid} = Parent.GenServer.start_child(child_spec)
      {%{id: child_spec.id, pid: child_pid, meta: child_spec.meta}, state}
    end)
  end
end
