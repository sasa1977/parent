defmodule Parent.SupervisorTest do
  use ExUnit.Case, async: true
  import Parent.CaptureLog
  alias Parent.Supervisor

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the given children" do
      start_supervised!({
        Supervisor,
        name: :my_supervisor,
        children: [
          child_spec(id: :child1),
          child_spec(id: :child2, start: fn -> :ignore end),
          Parent.child_spec(
            {Registry, name: :registry, keys: :unique},
            id: :child3
          )
        ]
      })

      assert [
               {:child1, _pid1, :worker, [Agent]},
               {:child3, _pid2, :supervisor, [Registry]}
             ] = :supervisor.which_children(:my_supervisor)
    end

    test "fails to start if a child fails to start" do
      Process.flag(:trap_exit, true)
      children = [child_spec(id: :child1, start: fn -> {:error, :some_reason} end)]

      assert capture_log(fn ->
               assert Supervisor.start_link(children: children) == {:error, :start_error}
             end) =~ "[error] Error starting the child :child1: :some_reason"
    end
  end

  describe "start_child/1" do
    test "adds the additional child" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child1)]})
      assert {:ok, child2} = Supervisor.start_child(pid, child_spec(id: :child2))
      assert [{:child1, _pid1, _, _}, {:child2, ^child2, _, _}] = :supervisor.which_children(pid)
    end

    test "returns error" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child1)]})
      {:ok, child2} = Supervisor.start_child(pid, child_spec(id: :child2))

      assert Supervisor.start_child(pid, child_spec(id: :child2)) ==
               {:error, {:already_started, child2}}

      assert [{:child1, _pid1, _, _}, {:child2, ^child2, _, _}] = :supervisor.which_children(pid)
    end

    test "handles child start crash" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child1)]})

      capture_log(fn ->
        spec =
          child_spec(id: :child2, start: {Agent, :start_link, [fn -> raise "some error" end]})

        assert {:error, {error, _stacktrace}} = Supervisor.start_child(pid, spec)
        Process.sleep(100)
      end)

      assert [{:child1, _pid1, _, _}] = :supervisor.which_children(pid)
    end

    test "handles :ignore" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child1)]})

      assert Supervisor.start_child(pid, child_spec(id: :child2, start: fn -> :ignore end)) ==
               {:ok, :undefined}

      assert [{:child1, _pid1, _, _}] = :supervisor.which_children(pid)
    end
  end

  describe "shutdown_child/1" do
    test "stops the given child" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child, register?: true)]})
      assert {:ok, _info} = Supervisor.shutdown_child(pid, :child)
      assert is_nil(Parent.whereis_child(pid, :child))
      assert :supervisor.which_children(pid) == []
    end

    test "returns error when child is unknown" do
      pid = start_supervised!({Supervisor, children: []})
      assert Supervisor.shutdown_child(pid, :child) == {:error, :unknown_child}
    end
  end

  describe "restart_child/1" do
    test "stops the given child" do
      pid = start_supervised!({Supervisor, children: [child_spec(id: :child, register?: true)]})
      pid1 = Parent.whereis_child(pid, :child)
      assert Supervisor.restart_child(pid, :child) == :ok
      refute Parent.whereis_child(pid, :child) == pid1
      assert [{:child, _, _, _}] = :supervisor.which_children(pid)
    end

    test "returns error when child is unknown" do
      pid = start_supervised!({Supervisor, children: []})
      assert Supervisor.restart_child(pid, :child) == {:error, :unknown_child}
    end
  end

  describe "shutdown_all/1" do
    test "stops all children" do
      pid =
        start_supervised!(
          {Supervisor,
           children: [
             child_spec(id: :child1, register?: true),
             child_spec(id: :child2, register?: true)
           ]}
        )

      assert Supervisor.shutdown_all(pid) == :ok
      assert is_nil(Parent.whereis_child(pid, :child1))
      assert is_nil(Parent.whereis_child(pid, :child2))
      assert :supervisor.which_children(pid) == []
    end
  end

  describe "return_children/1" do
    test "returns all given children" do
      pid =
        start_supervised!(
          {Supervisor,
           children: [
             child_spec(id: :child1, shutdown_group: :group1),
             child_spec(id: :child2, binds_to: [:child1], shutdown_group: :group2),
             child_spec(id: :child3, binds_to: [:child2]),
             child_spec(id: :child4, shutdown_group: :group1),
             child_spec(id: :child5, shutdown_group: :group2),
             child_spec(id: :child6)
           ]}
        )

      {:ok, %{return_info: return_info}} = Supervisor.shutdown_child(pid, :child4)
      assert [{:child6, _, _, _}] = :supervisor.which_children(pid)

      assert Supervisor.return_children(pid, return_info) == :ok

      assert Enum.map(:supervisor.which_children(pid), fn {id, _, _, _} -> id end) ==
               ~w/child1 child2 child3 child4 child5 child6/a
    end
  end

  test "restarts the child automatically" do
    pid =
      start_supervised!({
        Supervisor,
        name: :my_supervisor, children: [child_spec(id: :child1, register?: true)]
      })

    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)

    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({Parent, :return_children, 2}, [], [:local])

    pid1 = Parent.whereis_child(:my_supervisor, :child1)
    Agent.stop(pid1)

    assert_receive {:trace, ^pid, :call, {Parent, :return_children, _args}}

    refute Parent.whereis_child(:my_supervisor, :child1) == pid1
  end

  defp child_spec(overrides) do
    Map.merge(
      %{id: make_ref(), start: {Agent, :start_link, [fn -> :ok end]}},
      Map.new(overrides)
    )
  end
end
