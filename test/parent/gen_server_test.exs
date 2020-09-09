defmodule Parent.GenServerTest do
  use ExUnit.Case, async: true
  alias Parent.{Client, TestServer}

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

  test "invokes handle_stopped_children/2 when a temporary worker stops" do
    server = start_server!()

    child = start_child!(server, id: :child, meta: :meta, restart: :temporary)

    :erlang.trace(server, true, [:call])
    :erlang.trace_pattern({TestServer, :handle_stopped_children, 2}, [])

    Process.exit(child, :kill)

    assert_receive {:trace, ^server, :call,
                    {Parent.TestServer, :handle_stopped_children, [info, :initial_state]}}

    assert %{child: %{pid: pid, meta: meta, exit_reason: killed}} = info
  end

  test "restarts the child automatically" do
    server = start_server!(name: :my_server, children: [child_spec(id: :child)])

    :erlang.trace(server, true, [:call])
    :erlang.trace_pattern({Parent, :do_return_children, 3}, [], [:local])
    Agent.stop(child_pid!(server, :child))
    assert_receive {:trace, ^server, :call, {Parent, :do_return_children, _args}}

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
    Client.start_child(server, child_spec)
  end

  defp start_child!(server, overrides) do
    {:ok, pid} = start_child(server, overrides)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)

  defp child_pid!(server, child_id) do
    {:ok, pid} = Client.child_pid(server, child_id)
    pid
  end

  defp child_ids(parent), do: Enum.map(Client.children(parent), & &1.id)
end
