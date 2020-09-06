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
      start_supervisor!(
        name: :my_supervisor,
        children: [
          child_spec(id: :child1),
          child_spec(id: :child2, start: fn -> :ignore end),
          Parent.child_spec(
            {Registry, name: :registry, keys: :unique},
            id: :child3
          )
        ]
      )

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

  describe "child_pid/1" do
    test "returns the pid of the given child" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1), child_spec(id: :child2)])
      assert {:ok, pid1} = Supervisor.child_pid(supervisor, :child1)
      assert {:ok, pid2} = Supervisor.child_pid(supervisor, :child1)

      assert [{:child1, pid1, _, _}, {:child2, pid2, _, _}] =
               :supervisor.which_children(supervisor)
    end

    test "returns error when child is unknown" do
      supervisor = start_supervisor!()
      assert Supervisor.child_pid(supervisor, :child) == :error
    end
  end

  describe "child_meta/1" do
    test "returns the meta of the given child" do
      supervisor =
        start_supervisor!(
          children: [
            child_spec(id: :child1, meta: :meta1),
            child_spec(id: :child2, meta: :meta2)
          ]
        )

      assert Supervisor.child_meta(supervisor, :child1) == {:ok, :meta1}
      assert Supervisor.child_meta(supervisor, :child2) == {:ok, :meta2}
    end

    test "returns error when child is unknown" do
      supervisor = start_supervisor!()
      assert Supervisor.child_meta(supervisor, :child) == :error
    end
  end

  describe "update_child_meta/1" do
    test "succeeds if child exists" do
      supervisor = start_supervisor!(children: [child_spec(id: :child, meta: 1)])
      assert Supervisor.update_child_meta(supervisor, :child, &(&1 + 1))
      assert Supervisor.child_meta(supervisor, :child) == {:ok, 2}
    end

    test "returns error when child is unknown" do
      supervisor = start_supervisor!()
      assert Supervisor.update_child_meta(supervisor, :child, & &1) == :error
    end
  end

  describe "start_child/1" do
    test "adds the additional child" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1)])
      assert {:ok, child2} = Supervisor.start_child(supervisor, child_spec(id: :child2))
      assert child_pid!(supervisor, :child2) == child2
    end

    test "returns error" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1)])
      {:ok, child2} = Supervisor.start_child(supervisor, child_spec(id: :child2))

      assert Supervisor.start_child(supervisor, child_spec(id: :child2)) ==
               {:error, {:already_started, child2}}

      assert child_ids(supervisor) == [:child1, :child2]
      assert child_pid!(supervisor, :child2) == child2
    end

    test "handles child start crash" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1)])

      capture_log(fn ->
        spec =
          child_spec(id: :child2, start: {Agent, :start_link, [fn -> raise "some error" end]})

        assert {:error, {error, _stacktrace}} = Supervisor.start_child(supervisor, spec)
        Process.sleep(100)
      end)

      assert child_ids(supervisor) == [:child1]
    end

    test "handles :ignore" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1)])

      assert Supervisor.start_child(supervisor, child_spec(id: :child2, start: fn -> :ignore end)) ==
               {:ok, :undefined}

      assert child_ids(supervisor) == [:child1]
    end
  end

  describe "shutdown_child/1" do
    test "stops the given child" do
      supervisor = start_supervisor!(children: [child_spec(id: :child)])
      assert {:ok, _info} = Supervisor.shutdown_child(supervisor, :child)
      assert Supervisor.child_pid(supervisor, :child) == :error
      assert child_ids(supervisor) == []
    end

    test "returns error when child is unknown" do
      supervisor = start_supervisor!()
      assert Supervisor.shutdown_child(supervisor, :child) == {:error, :unknown_child}
    end
  end

  describe "restart_child/1" do
    test "stops the given child" do
      supervisor = start_supervisor!(children: [child_spec(id: :child)])
      pid1 = child_pid!(supervisor, :child)
      assert Supervisor.restart_child(supervisor, :child) == :ok
      assert child_ids(supervisor) == [:child]
      refute child_pid!(supervisor, :child) == pid1
    end

    test "returns error when child is unknown" do
      pid = start_supervisor!()
      assert Supervisor.restart_child(pid, :child) == {:error, :unknown_child}
    end
  end

  describe "shutdown_all/1" do
    test "stops all children" do
      supervisor = start_supervisor!(children: [child_spec(id: :child1), child_spec(id: :child2)])
      assert Supervisor.shutdown_all(supervisor) == :ok
      assert child_ids(supervisor) == []
    end
  end

  describe "return_children/1" do
    test "returns all given children" do
      supervisor =
        start_supervisor!(
          children: [
            child_spec(id: :child1, shutdown_group: :group1),
            child_spec(id: :child2, binds_to: [:child1], shutdown_group: :group2),
            child_spec(id: :child3, binds_to: [:child2]),
            child_spec(id: :child4, shutdown_group: :group1),
            child_spec(id: :child5, shutdown_group: :group2),
            child_spec(id: :child6)
          ]
        )

      {:ok, %{return_info: return_info}} = Supervisor.shutdown_child(supervisor, :child4)
      assert child_ids(supervisor) == [:child6]

      assert Supervisor.return_children(supervisor, return_info) == :ok
      assert child_ids(supervisor) == ~w/child1 child2 child3 child4 child5 child6/a
    end
  end

  test "restarts the child automatically" do
    supervisor = start_supervisor!(name: :my_supervisor, children: [child_spec(id: :child)])

    :erlang.trace(supervisor, true, [:call])
    :erlang.trace_pattern({Parent, :return_children, 2}, [], [:local])
    Agent.stop(child_pid!(supervisor, :child))
    assert_receive {:trace, ^supervisor, :call, {Parent, :return_children, _args}}

    assert child_ids(supervisor) == [:child]
  end

  defp start_supervisor!(opts \\ []) do
    pid = start_supervised!({Supervisor, opts})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)

  defp child_pid!(supervisor, child_id) do
    {:ok, pid} = Supervisor.child_pid(supervisor, child_id)
    pid
  end

  defp child_ids(supervisor) do
    supervisor
    |> :supervisor.which_children()
    |> Enum.map(fn {child_id, _, _, _} -> child_id end)
  end
end
