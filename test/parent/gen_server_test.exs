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
    server = start_server!()
    assert :sys.get_state(server) == :initial_state
  end

  test "call" do
    server = start_server!()

    assert TestServer.call(server, fn state -> {{:response, state}, :new_state} end) ==
             {:response, :initial_state}

    assert :sys.get_state(server) == :new_state
  end

  test "call which throws a reply" do
    server = start_server!()

    assert TestServer.call(server, fn _state -> throw({:reply, :response, :new_state}) end)
    assert :sys.get_state(server) == :new_state
  end

  test "cast" do
    server = start_server!()
    assert TestServer.cast(server, fn state -> {:updated_state, state} end) == :ok
    assert :sys.get_state(server) == {:updated_state, :initial_state}
  end

  test "send" do
    server = start_server!()
    TestServer.send(server, fn state -> {:updated_state, state} end)
    assert :sys.get_state(server) == {:updated_state, :initial_state}
  end

  test "terminates children before the parent stops" do
    server = start_server!(children: [child_spec(id: :child1), child_spec(id: :child2)])
    child1 = child_pid!(server, :child1)
    child2 = child_pid!(server, :child2)

    Process.monitor(server)
    Process.monitor(child1)
    Process.monitor(child2)

    GenServer.stop(server)

    assert_receive {:DOWN, _mref, :process, pid1, _reason}
    assert_receive {:DOWN, _mref, :process, pid2, _reason}
    assert_receive {:DOWN, _mref, :process, pid3, _reason}

    assert [pid1, pid2, pid3] == [child2, child1, server]
  end

  test "invokes handle_child_terminated/2 when a temporary worker stops" do
    server = start_server!()

    child = start_child!(server, id: :child, meta: :meta, restart: :temporary)

    :erlang.trace(server, true, [:call])
    :erlang.trace_pattern({TestServer, :handle_child_terminated, 2}, [])

    Process.exit(child, :kill)

    assert_receive {:trace, ^server, :call,
                    {Parent.TestServer, :handle_child_terminated, [info, :initial_state]}}

    assert Map.delete(info, :return_info) == %{
             id: :child,
             pid: child,
             meta: :meta,
             reason: :killed,
             also_terminated: []
           }
  end

  test "restarts the child automatically" do
    server = start_server!(name: :my_server, children: [child_spec(id: :child)])

    :erlang.trace(server, true, [:call])
    :erlang.trace_pattern({Parent, :return_children, 2}, [], [:local])
    Agent.stop(child_pid!(server, :child))
    assert_receive {:trace, ^server, :call, {Parent, :return_children, _args}}

    assert child_ids(server) == [:child]
  end

  test "registers the process" do
    server = start_server!(name: :registered_name)
    assert Process.whereis(:registered_name) == server
  end

  describe "supervisor calls" do
    test "which_children" do
      server =
        start_server!(
          children: [
            [id: :child1, type: :worker],
            [id: :child2, type: :supervisor]
          ]
        )

      assert [child1, child2] = :supervisor.which_children(server)
      assert {:child1, _pid, :worker, _} = child1
      assert {:child2, _pid, :supervisor, _} = child2
    end

    test "count_children" do
      server =
        start_server!(
          children: [
            [id: :child1, type: :worker],
            [id: :child2, type: :supervisor]
          ]
        )

      assert :supervisor.count_children(server) == [
               active: 2,
               specs: 2,
               supervisors: 1,
               workers: 1
             ]
    end

    test "get_childspec" do
      server = start_server!(children: [[id: :child1, type: :worker]])
      assert {:ok, %{id: :child1, type: :worker}} = :supervisor.get_childspec(server, :child1)
    end

    test "get callback module" do
      server = start_server!()
      assert :supervisor.get_callback_module(server) == TestServer
    end
  end

  defp start_server!(opts \\ []) do
    {children, opts} = Keyword.pop(opts, :children, [])
    server = start_supervised!({TestServer, {fn -> :initial_state end, opts}})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), server)
    Enum.each(children, &start_child!(server, &1))
    server
  end

  defp start_child(server, overrides) do
    child_spec = Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)
    start = {Agent, :start_link, fn -> :ok end}
    child_spec = Map.merge(%{meta: {child_spec.id, :meta}, start: start}, child_spec)
    Parent.Client.start_child(server, child_spec)
  end

  defp start_child!(server, overrides) do
    {:ok, pid} = start_child(server, overrides)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)

  defp child_pid!(server, child_id) do
    {:ok, pid} = Parent.Client.child_pid(server, child_id)
    pid
  end

  defp child_ids(server) do
    server
    |> :supervisor.which_children()
    |> Enum.map(fn {child_id, _, _, _} -> child_id end)
  end
end
