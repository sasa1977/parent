defmodule Parent.GenServerTest do
  use ExUnit.Case, async: true
  alias Parent.TestServer

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ok
  end

  test "init" do
    pid = start_test_server!()
    assert :sys.get_state(pid) == :initial_state
  end

  test "call" do
    pid = start_test_server!()

    assert TestServer.call(pid, fn state -> {{:response, state}, :new_state} end) ==
             {:response, :initial_state}

    assert :sys.get_state(pid) == :new_state
  end

  test "call which throws a reply" do
    pid = start_test_server!()

    assert TestServer.call(pid, fn _state -> throw({:reply, :response, :new_state}) end)
    assert :sys.get_state(pid) == :new_state
  end

  test "cast" do
    pid = start_test_server!()
    assert TestServer.cast(pid, fn state -> {:updated_state, state} end) == :ok
    assert :sys.get_state(pid) == {:updated_state, :initial_state}
  end

  test "send" do
    pid = start_test_server!()
    TestServer.send(pid, fn state -> {:updated_state, state} end)
    assert :sys.get_state(pid) == {:updated_state, :initial_state}
  end

  test "starting a child" do
    parent = start_test_server!()

    child_id = make_ref()

    start_child(parent, %{
      id: child_id,
      start: {Agent, :start_link, [fn -> :ok end]},
      type: :worker
    })

    assert TestServer.call(parent, fn state -> {Parent.child?(child_id), state} end)
  end

  test "terminates children before the parent stops" do
    parent = start_test_server!()

    child_id = make_ref()

    start_child(parent, %{
      id: child_id,
      start: {Agent, :start_link, [fn -> :ok end]},
      type: :worker
    })

    {:ok, child} = TestServer.call(parent, fn state -> {Parent.child_pid(child_id), state} end)

    Process.monitor(parent)
    Process.monitor(child)

    GenServer.stop(parent)

    assert_receive {:DOWN, _mref, :process, pid1, _reason}
    assert_receive {:DOWN, _mref, :process, pid2, _reason}

    assert [pid1, pid2] == [child, parent]
  end

  test "invokes handle_child_terminated/2 when a temporary worker stops" do
    parent = start_test_server!()

    child_id = make_ref()

    child_pid =
      start_child(parent, %{
        id: child_id,
        start: {Agent, :start_link, [fn -> :ok end]},
        meta: :meta,
        type: :worker,
        restart: :never
      }).pid

    :erlang.trace(parent, true, [:call])
    :erlang.trace_pattern({TestServer, :handle_child_terminated, 2}, [])

    Process.exit(child_pid, :kill)

    assert_receive {:trace, ^parent, :call,
                    {Parent.TestServer, :handle_child_terminated, [info, :initial_state]}}

    assert info == %{
             id: child_id,
             pid: child_pid,
             meta: :meta,
             reason: :killed,
             also_terminated: []
           }
  end

  test "invokes handle_child_restarted/2 when a permanent worker stops and restarts the child" do
    parent = start_test_server!()

    child_id = make_ref()

    child_pid =
      start_child(parent, %{
        id: child_id,
        start: {Agent, :start_link, [fn -> :ok end]},
        meta: :meta,
        type: :worker
      }).pid

    :erlang.trace(parent, true, [:call])
    :erlang.trace_pattern({TestServer, :handle_child_restarted, 2}, [])

    Process.exit(child_pid, :kill)

    assert_receive {:trace, ^parent, :call,
                    {Parent.TestServer, :handle_child_restarted, [info, :initial_state]}}

    assert info.id == child_id
    assert info.reason == :killed
    assert [child] = TestServer.call(parent, &{Parent.children(), &1})
    assert child.id == child_id
    assert child.meta == :meta
    refute child.pid == child_pid
  end

  describe "supervisor" do
    test "which children" do
      pid = start_test_server!()

      child_specs =
        Enum.map([{1, :worker}, {2, :supervisor}], fn {id, type} ->
          start_child(pid, %{id: id, start: {Agent, :start_link, [fn -> :ok end]}, type: type})
        end)

      assert [child1, child2] = :supervisor.which_children(pid)
      assert {1, pid1, :worker, [Agent]} = child1
      assert Enum.find(child_specs, &(&1.id == 1)).pid == pid1

      assert {2, pid2, :supervisor, [Agent]} = child2
      assert Enum.find(child_specs, &(&1.id == 2)).pid == pid2
    end

    test "count children" do
      pid = start_test_server!()

      Enum.map([{1, :worker}, {2, :supervisor}], fn {id, type} ->
        start_child(pid, %{id: id, start: {Agent, :start_link, [fn -> :ok end]}, type: type})
      end)

      assert :supervisor.count_children(pid) == [active: 2, specs: 2, supervisors: 1, workers: 1]
    end

    test "get callback module" do
      pid = start_test_server!()
      assert :supervisor.get_callback_module(pid) == TestServer
    end
  end

  defp start_test_server! do
    pid = start_supervised!({TestServer, fn -> :initial_state end})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp start_child(parent_pid, child_spec) do
    id = Map.get(child_spec, :id, make_ref())
    child_spec = Map.merge(%{id: id, meta: {id, :meta}}, child_spec)

    result =
      TestServer.call(parent_pid, fn state ->
        {:ok, child_pid} = Parent.start_child(child_spec)
        {%{id: child_spec.id, pid: child_pid, meta: child_spec.meta}, state}
      end)

    result
  end
end
