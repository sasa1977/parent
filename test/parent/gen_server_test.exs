defmodule Parent.GenServerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.TestServer

  property "commands" do
    check all initial_state <- term(),
              commands <- commands() do
      {:ok, pid} = TestServer.start_link(fn -> initial_state end)
      assert :sys.get_state(pid) == initial_state
      Enum.each(commands, &verify_command(&1, pid))
    end
  end

  defp verify_command(:test_call, pid) do
    response = make_ref()
    new_state = make_ref()
    assert TestServer.call(pid, fn _ -> {response, new_state} end) == response
    assert :sys.get_state(pid) == new_state
  end

  defp verify_command(:test_cast, pid) do
    new_state = make_ref()
    assert TestServer.cast(pid, fn _ -> new_state end) == :ok
    assert :sys.get_state(pid) == new_state
  end

  defp verify_command(:test_send, pid) do
    new_state = make_ref()
    TestServer.send(pid, fn _ -> new_state end)
    assert :sys.get_state(pid) == new_state
  end

  defp verify_command(:start_job, pid) do
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

  defp verify_command({:stop_job, shutdown_type}, pid) do
    children = record_child_change(pid, nil, fn -> nil end).after.children

    if Enum.count(children) > 0 do
      [{child_id, child_pid, meta}] = Enum.take(children, 1)

      mref = Process.monitor(child_pid)

      change =
        record_child_change(pid, child_id, fn ->
          stop_child(pid, child_pid, child_id, shutdown_type)
        end)

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

      if shutdown_type == :shutdown do
        assert terminated_info == nil
      else
        expected_reason = if shutdown_type == :kill, do: :killed, else: shutdown_type

        assert terminated_info == %{
                 id: child_id,
                 meta: meta,
                 pid: child_pid,
                 reason: expected_reason
               }
      end
    end
  end

  defp verify_command(:shutdown_all, pid) do
    change =
      record_child_change(pid, nil, fn ->
        Parent.GenServer.shutdown_all()
      end)

    assert change.after.num_children == 0
    Enum.each(change.before.children, fn {_id, pid, _meta} -> refute Process.alive?(pid) end)
  end

  defp verify_command(:update_meta, pid) do
    children = record_child_change(pid, nil, fn -> nil end).after.children

    if Enum.count(children) > 0 do
      [{child_id, _child_pid, meta}] = Enum.take(children, 1)

      TestServer.call(pid, fn state ->
        meta_updater = &{:updated, &1}
        assert :ok = Parent.GenServer.update_child_meta(child_id, meta_updater)
        assert Parent.GenServer.child_meta(child_id) == {:ok, meta_updater.(meta)}
        {:ok, state}
      end)
    end
  end

  defp commands() do
    [
      :test_call,
      :test_cast,
      :test_send,
      :start_job,
      {:stop_job, shutdown_type()},
      :shutdown_all,
      :update_meta
    ]
    |> one_of()
    |> list_of()
    |> nonempty()
  end

  defp shutdown_type(), do: one_of([:normal, :shutdown, :crash, :kill])

  defp stop_child(_parent_pid, child_pid, _child_id, :normal), do: Agent.stop(child_pid)

  defp stop_child(_parent_pid, child_pid, _child_id, :crash), do: Process.exit(child_pid, :crash)

  defp stop_child(_parent_pid, child_pid, _child_id, :kill), do: Process.exit(child_pid, :kill)

  defp stop_child(parent_pid, _child_pid, child_id, :shutdown) do
    TestServer.cast(parent_pid, fn state ->
      Parent.GenServer.shutdown_child(child_id)
      state
    end)
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
end
