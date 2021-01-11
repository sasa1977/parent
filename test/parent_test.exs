defmodule ParentTest do
  use ExUnit.Case, async: true
  import Parent.CaptureLog

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ets.new(__MODULE__, [:named_table, :public])

    :ok
  end

  describe "child_spec/2" do
    defmodule TestChildSpec do
      def child_spec(arg), do: %{start: {__MODULE__, :start_link, arg}}
    end

    test "expands module, passing empty list as the arg" do
      expanded_spec = Parent.child_spec(TestChildSpec)
      assert is_map(expanded_spec)
      assert expanded_spec.start == {TestChildSpec, :start_link, []}
    end

    test "expands {module, opts}" do
      expanded_spec = Parent.child_spec({TestChildSpec, :some_arg})
      assert is_map(expanded_spec)
      assert expanded_spec.start == {TestChildSpec, :start_link, :some_arg}
    end

    for {opt, default} <- [
          binds_to: [],
          ephemeral?: false,
          id: nil,
          max_restarts: :infinity,
          max_seconds: 5000,
          meta: nil,
          restart: :permanent,
          shutdown: 5000,
          shutdown_group: nil,
          timeout: :infinity,
          type: :worker
        ] do
      test "sets #{opt} to #{inspect(default)} by default" do
        spec = Parent.child_spec(%{start: fn -> :ok end})
        assert Map.fetch!(spec, unquote(opt)) == unquote(default)
      end
    end

    test "sets shutdown to infinity if the child is a supervisor" do
      assert Parent.child_spec(%{start: fn -> :ok end, type: :supervisor}).shutdown == :infinity
    end

    test "sets shutdown to 5000 if the child is a worker" do
      assert Parent.child_spec(%{start: fn -> :ok end, type: :worker}).shutdown == 5000
    end

    test "sets the default modules" do
      assert Parent.child_spec({Agent, fn -> :ok end}).modules == [Agent]
      assert Parent.child_spec(%{start: fn -> :ok end}).modules == [__MODULE__]
    end

    test "applies overrides on top of defaults" do
      assert Parent.child_spec({Agent, fn -> :ok end}, shutdown: 0).shutdown == 0
    end

    test "succeeds if base spec doesn't contain the start spec" do
      start = {Agent, :start_link, fn -> :ok end}
      assert Parent.child_spec(%{}, start: start).start == start
    end
  end

  describe "initialize/0" do
    test "traps exists" do
      Process.flag(:trap_exit, false)
      Parent.initialize()
      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    end

    test "raises if called multiple times" do
      Parent.initialize()
      assert_raise RuntimeError, "Parent state is already initialized", &Parent.initialize/0
    end
  end

  describe "start_child" do
    test "returns the pid of the started process on success" do
      Parent.initialize()
      parent = self()
      assert {:ok, child} = Parent.start_child({Task, fn -> send(parent, self()) end})
      assert_receive ^child
    end

    test "implicitly sets the id" do
      Parent.initialize()
      {:ok, child1} = Parent.start_child(%{start: fn -> Agent.start_link(fn -> :ok end) end})
      {:ok, child2} = Parent.start_child(%{start: fn -> Agent.start_link(fn -> :ok end) end})
      assert [%{pid: ^child1}, %{pid: ^child2}] = Parent.children()
    end

    test "accepts module for child spec" do
      defmodule TestChild1 do
        def child_spec(_arg) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :ok end]}
          }
        end
      end

      Parent.initialize()
      assert {:ok, _child} = Parent.start_child(TestChild1)
      assert Parent.child?(TestChild1)
    end

    test "accepts {module, arg} for child spec" do
      defmodule TestChild2 do
        def child_spec(caller) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> send(caller, :called) end]}
          }
        end
      end

      Parent.initialize()
      assert {:ok, _child} = Parent.start_child({TestChild2, self()})
      assert_receive :called
      assert Parent.child?(TestChild2)
    end

    test "accepts a child specification map" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: {Agent, :start_link, [fn -> :ok end]}})
    end

    test "accepts a zero arity function in the :start key of the child spec" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: fn -> Agent.start_link(fn -> :ok end) end})
    end

    test "succeeds if deps are started" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2)
      assert {:ok, _pid} = start_child(binds_to: ~w/child1 child2/a)
    end

    test "starts a child if it depends on non-running process" do
      Parent.initialize()
      start_child!(id: :child1, start: fn -> :ignore end)
      assert {:ok, _} = start_child(id: :child2, binds_to: [:child1])
    end

    test "keeps ignored non-ephemeral children in the state" do
      Parent.initialize()

      assert start_child(id: :child1, start: fn -> :ignore end, ephemeral?: false) ==
               {:ok, :undefined}

      assert start_child(id: :child2, start: fn -> :ignore end, ephemeral?: false) ==
               {:ok, :undefined}

      assert Parent.child_pid(:child1) == {:ok, :undefined}
      assert Parent.child_pid(:child2) == {:ok, :undefined}
    end

    test "doesn't keep ephemeral child in the state" do
      Parent.initialize()

      assert start_child(id: :child, start: fn -> :ignore end, ephemeral?: true) ==
               {:ok, :undefined}

      assert Parent.child_pid(:child) == :error
    end

    test "handles error by the started process" do
      Parent.initialize()
      assert start_child(start: fn -> {:error, :some_reason} end) == {:error, :some_reason}
    end

    test "fails if id is already taken" do
      Parent.initialize()
      child = start_child!(id: :child)
      assert start_child(id: :child) == {:error, {:already_started, child}}
    end

    test "fails if id is pid" do
      Parent.initialize()
      assert start_child(id: self()) == {:error, :invalid_child_id}
    end

    test "fails if deps are not started" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2)

      assert {:error, error} = start_child(binds_to: ~w/child1 child2 child4 child5/a)
      assert error == {:missing_deps, ~w/child4 child5/a}
    end

    test "fails when children in a shutdown group don't have the same restart type" do
      Parent.initialize()

      for r1 <- ~w/temporary transient temporary/a,
          r2 <- ~w/temporary transient temporary/a,
          r1 != r2 do
        Parent.shutdown_all()
        start_child!(id: :child1, restart: r1, shutdown_group: :group)

        assert start_child(id: :child2, restart: r2, shutdown_group: :group) ==
                 {:error, {:non_uniform_shutdown_group, :group}}
      end
    end

    test "fails when children in a shutdown group don't have the same ephemeral setting" do
      Parent.initialize()

      start_child!(id: :child1, ephemeral?: false, shutdown_group: :group)

      assert start_child(id: :child2, ephemeral?: true, shutdown_group: :group) ==
               {:error, {:non_uniform_shutdown_group, :group}}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &start_child/0
    end
  end

  describe "start_all_children/1" do
    test "starts all processes" do
      Parent.initialize()

      assert [child1, :undefined, child3] =
               Parent.start_all_children!([
                 Parent.child_spec({Agent, fn -> :ok end}, id: :child1),
                 %{id: :child2, start: fn -> :ignore end},
                 Parent.child_spec({Agent, fn -> :ok end}, id: :child3)
               ])

      assert Parent.child_pid(:child1) == {:ok, child1}
      assert Parent.child_pid(:child3) == {:ok, child3}
    end

    test "exits at first error" do
      Parent.initialize()
      test_pid = self()

      log =
        capture_log(fn ->
          assert catch_exit(
                   Parent.start_all_children!([
                     {Agent, fn -> :ok end},
                     %{id: :child2, start: fn -> {:error, :some_error} end},
                     {Agent, fn -> send(test_pid, :child3_started) end}
                   ])
                 ) == :start_error
        end)

      assert log =~ "Error starting the child :child2: :some_error"

      refute_receive :child3_started
      assert Parent.num_children() == 0
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.start_all_children!([Agent])
      end
    end
  end

  describe "shutdown_child/1" do
    test "stops the child synchronously, handling the exit message" do
      Parent.initialize()
      child = start_child!(id: :child)

      assert {:ok, stopped_children} = Parent.shutdown_child(:child)
      assert Map.keys(stopped_children) == [:child]

      refute Process.alive?(child)
      refute_receive {:EXIT, ^child, _reason}
      assert Parent.children() == []
    end

    test "stops the child referenced by the pid" do
      Parent.initialize()
      child = start_child!(id: :child)

      Parent.shutdown_child(child)

      refute Process.alive?(child)
      assert Parent.children() == []
    end

    test "forcefully terminates the child if shutdown is `:brutal_kill`" do
      Parent.initialize()
      test_pid = self()

      child =
        start_child!(
          id: :child,
          shutdown: :brutal_kill,
          start: fn ->
            Task.start_link(fn ->
              Process.flag(:trap_exit, true)
              send(test_pid, :continue)
              Process.sleep(:infinity)
            end)
          end
        )

      Process.monitor(child)
      assert_receive :continue
      Parent.shutdown_child(:child)
      assert_receive {:DOWN, _mref, :process, ^child, :killed}
    end

    test "forcefully terminates a child if it doesn't stop in the given time" do
      Parent.initialize()
      test_pid = self()

      child =
        start_child!(
          id: :child,
          shutdown: 10,
          start: fn ->
            Task.start_link(fn ->
              Process.flag(:trap_exit, true)
              send(test_pid, :continue)
              Process.sleep(:infinity)
            end)
          end
        )

      Process.monitor(child)
      assert_receive :continue
      Parent.shutdown_child(:child)
      assert_receive {:DOWN, _mref, :process, ^child, :killed}
    end

    test "can stop a non-running child" do
      Parent.initialize()

      start_child!(id: :child1, start: fn -> :ignore end)
      start_child!(id: :child2, start: fn -> :ignore end)

      assert {:ok, %{child1: %{pid: :undefined}}} = Parent.shutdown_child(:child1)
      assert [%{id: :child2}] = Parent.children()
    end

    test "fails if an unknown child is given" do
      Parent.initialize()
      assert Parent.shutdown_child(:child) == :error
    end

    test "stops all dependencies in the opposite startup order" do
      Parent.initialize()

      child1 = start_child!(id: :child1, shutdown_group: :group1)
      child2 = start_child!(id: :child2, binds_to: [:child1], shutdown_group: :group2)
      child3 = start_child!(id: :child3, binds_to: [:child2])
      child4 = start_child!(id: :child4, shutdown_group: :group1)
      child5 = start_child!(id: :child5, shutdown_group: :group2)
      start_child!(id: :child6)

      Enum.each([child1, child2, child3, child4, child5], &Process.monitor/1)

      assert {:ok, stopped_children} = Parent.shutdown_child(:child4)
      assert Map.keys(stopped_children) == ~w/child1 child2 child3 child4 child5/a
      assert [%{id: :child6}] = Parent.children()

      pids =
        Enum.map(1..5, fn _ ->
          assert_receive {:DOWN, _mref, :process, pid, _reason}
          pid
        end)

      assert pids == [child5, child4, child3, child2, child1]
    end

    test "stops pid-references dependencies" do
      Parent.initialize()

      child1 = start_child!(shutdown_group: :group1)
      child2 = start_child!(binds_to: [child1], shutdown_group: :group2)
      child3 = start_child!(binds_to: [child2])
      child4 = start_child!(shutdown_group: :group1)
      child5 = start_child!(shutdown_group: :group2)
      child6 = start_child!()

      assert {:ok, stopped_children} = Parent.shutdown_child(child4)
      assert Map.keys(stopped_children) == [child1, child2, child3, child4, child5]
      assert [%{pid: ^child6}] = Parent.children()
    end

    test "stops a non-running dependency" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2, start: fn -> :ignore end, binds_to: [:child1])

      assert {:ok, %{child2: %{pid: :undefined}}} = Parent.shutdown_child(:child1)
      assert Parent.children() == []
    end

    test "works if a bound child stopped previously" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1])
      start_child!(id: :child3, binds_to: [:child1])

      {:ok, _} = Parent.shutdown_child(:child2)
      assert {:ok, stopped_children} = Parent.shutdown_child(:child1)
      assert Map.keys(stopped_children) == [:child1, :child3]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.shutdown_child(1) end
    end
  end

  describe "restart_child" do
    test "restarts the process and returns the new pid" do
      Parent.initialize()
      child = start_child!(id: :child)
      assert Parent.restart_child(:child) == :ok
      assert [%{id: :child}] = Parent.children()
      refute child_pid!(:child) == child
    end

    test "restarts the process referenced by the pid" do
      Parent.initialize()
      child = start_child!(id: :child)
      assert Parent.restart_child(child) == :ok
      assert [%{id: :child}] = Parent.children()
      refute child_pid!(:child) == child
    end

    test "can restart a non-running child" do
      Parent.initialize()
      start_child!(id: :child, start: fn -> :ignore end)

      assert Parent.restart_child(:child) == :ok
      assert [%{id: :child}] = Parent.children()

      # trying once more to verify that a child is successfully reregistered
      assert Parent.restart_child(:child) == :ok
      assert [%{id: :child}] = Parent.children()
    end

    test "preserves startup order" do
      Parent.initialize()
      child1 = start_child!(id: :child1)
      _child2 = start_child!(id: :child2)
      child3 = start_child!(id: :child3)

      Parent.restart_child(:child2)
      {:ok, child2} = Parent.child_pid(:child2)
      assert Enum.map(Parent.children(), & &1.pid) == [child1, child2, child3]
    end

    test "also restarts all bound siblings" do
      Parent.initialize()

      child1 = start_child!(id: :child1, shutdown_group: :group1)
      child2 = start_child!(id: :child2, binds_to: [:child1])
      child3 = start_child!(id: :child3, restart: :temporary, binds_to: [:child2])
      child4 = start_child!(id: :child4, shutdown_group: :group1)
      child5 = start_child!(id: :child5, restart: :transient, binds_to: [:child2])

      child6 =
        start_child!(id: :child6, ephemeral?: true, restart: :transient, binds_to: [:child2])

      child7 =
        start_child!(id: :child7, ephemeral?: true, restart: :temporary, binds_to: [:child2])

      child8 = start_child!(id: :child8)

      assert Parent.restart_child(:child4) == :ok

      refute child_pid!(:child1) == child1
      refute child_pid!(:child2) == child2
      refute child_pid!(:child3) == child3
      refute child_pid!(:child4) == child4
      refute child_pid!(:child5) == child5
      refute child_pid!(:child6) == child6
      refute child_pid!(:child7) == child7
      assert child_pid!(:child8) == child8
    end

    test "gradually retries child restart if the child fails to start" do
      Parent.initialize()

      start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1])

      raise_on_child_start(:child1)
      Parent.restart_child(:child1)
      assert_receive {:EXIT, _pid, _}

      succeed_on_child_start(:child1)
      raise_on_child_start(:child2)

      assert handle_parent_message() == :ignore
      assert_receive {:EXIT, _pid, _}

      succeed_on_child_start(:child2)
      assert [%{id: :child1}, %{id: :child2}] = Parent.children()
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.restart_child(1) end
    end
  end

  describe "child termination" do
    test "by default causes restart" do
      Parent.initialize()
      start_child!(id: :child)
      provoke_child_termination!(:child)
      assert Parent.child?(:child)
    end

    test "causes restart if a permanent child stops" do
      Parent.initialize()
      pid1 = start_child!(id: :child, meta: :meta, restart: :permanent)
      provoke_child_termination!(:child, restart: :shutdown)
      assert is_pid(child_pid!(:child))
      refute child_pid!(:child) == pid1
    end

    test "causes restart when a transient child terminates abnormally" do
      Parent.initialize()
      start_child!(id: :child, restart: :transient)
      provoke_child_termination!(:child)
      assert Parent.child?(:child)
    end

    test "causes restart when a child is terminated due to a timeout" do
      Parent.initialize()
      start_child!(id: :child, timeout: 0)
      :ignore = handle_parent_message()
      assert Parent.child?(:child)
    end

    test "doesn't cause restart if a temporary child terminates" do
      Parent.initialize()
      start_child!(id: :child, restart: :temporary)
      provoke_child_termination!(:child)
      assert Parent.child_pid(:child) == {:ok, :undefined}
    end

    test "doesn't cause restart if a transient child terminates normally" do
      Parent.initialize()
      start_child!(id: :child, restart: :transient, start: {Task, :start_link, [fn -> :ok end]})
      :ignore = handle_parent_message()
      assert Parent.child_pid(:child) == {:ok, :undefined}
    end

    test "doesn't cause restart when a child is terminated via `Parent` function" do
      Parent.initialize()
      start_child!(id: :child)
      Parent.shutdown_child(:child)

      refute_receive _
      refute Parent.child?(:child)
    end

    test "also restarts temporary bound siblings" do
      Parent.initialize()
      start_child!(id: :child1, restart: :permanent)

      child2 =
        start_child!(id: :child2, restart: :temporary, ephemeral?: false, binds_to: [:child1])

      child3 =
        start_child!(id: :child3, restart: :temporary, ephemeral?: true, binds_to: [:child1])

      provoke_child_termination!(:child1)
      refute child_pid!(:child2) in [:undefined, child2]
      refute child_pid!(:child3) in [:undefined, child3]
    end

    test "causes bound siblings to be stopped regardless of their restart strategy if the terminated child is not restarted" do
      Parent.initialize()
      start_child!(id: :child1, restart: :temporary)
      start_child!(id: :child2, restart: :transient, binds_to: [:child1])
      start_child!(id: :child3, restart: :permanent, binds_to: [:child1])

      provoke_child_termination!(:child1)
      assert child_pid!(:child1) == :undefined
      assert child_pid!(:child2) == :undefined
      assert child_pid!(:child3) == :undefined
    end

    test "causes bound siblings to be removed regardless of their ephemeral status or restart strategy if the terminated child is not restarted" do
      Parent.initialize()
      start_child!(id: :child1, restart: :temporary, ephemeral?: true)
      start_child!(id: :child2, restart: :transient, binds_to: [:child1])
      start_child!(id: :child3, restart: :permanent, binds_to: [:child1])

      assert {:stopped_children, stopped_children} = provoke_child_termination!(:child1)
      assert Enum.sort(Map.keys(stopped_children)) == ~w/child1 child2 child3/a
      assert Parent.children() == []
    end

    test "causes bound ephemeral siblings to be removed if a non-ephemeral terminated child is not restarted" do
      Parent.initialize()
      start_child!(id: :child1, restart: :temporary)
      start_child!(id: :child2, restart: :transient, ephemeral?: true, binds_to: [:child1])
      start_child!(id: :child3, restart: :permanent, ephemeral?: true, binds_to: [:child1])
      start_child!(id: :child4, restart: :permanent, ephemeral?: false, binds_to: [:child1])

      assert {:stopped_children, stopped_children} = provoke_child_termination!(:child1)
      assert Enum.sort(Map.keys(stopped_children)) == ~w/child2 child3/a

      assert [%{id: :child1, pid: :undefined}, %{id: :child4, pid: :undefined}] =
               Parent.children()
    end

    test "of an anonymous child also takes down anonymous bound siblings" do
      Parent.initialize()

      child1 = start_child!(restart: :temporary)
      child2 = start_child!(restart: :temporary, binds_to: [child1])
      child3 = start_child!(restart: :temporary, binds_to: [child2])

      Process.monitor(child2)
      Process.monitor(child3)

      provoke_child_termination!(child1)

      assert_receive {:DOWN, _mref, :process, ^child2, :shutdown}
      assert_receive {:DOWN, _mref, :process, ^child3, :shutdown}
    end

    test "takes down the entire parent on too many restarts" do
      Parent.initialize(max_restarts: 2)

      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)

      provoke_child_termination!(:child1)
      provoke_child_termination!(:child2)

      log = assert_parent_exit(fn -> provoke_child_termination!(:child3) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "takes down the entire parent on too many restarts of a single child" do
      Parent.initialize(max_restarts: :infinity)

      start_child!(id: :child1, max_restarts: 2, max_seconds: 1)
      start_child!(id: :child2)

      provoke_child_termination!(:child1)
      provoke_child_termination!(:child1)

      log = assert_parent_exit(fn -> provoke_child_termination!(:child1) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "doesn't stop parent if max_restarts of the child is infinity" do
      Parent.initialize(max_restarts: :infinity)
      start_child!(id: :child1, max_restarts: :infinity)

      provoke_child_termination!(:child1)
      provoke_child_termination!(:child1)
      provoke_child_termination!(:child1)
      provoke_child_termination!(:child1)
    end

    test "clears recorded restarts after the interval has passed" do
      Parent.initialize()

      start_child!(id: :child1, max_restarts: 2, max_seconds: 2)
      start_child!(id: :child2)

      provoke_child_termination!(:child1, at: :timer.seconds(0))
      provoke_child_termination!(:child1, at: :timer.seconds(1))
      provoke_child_termination!(:child1, at: :timer.seconds(2))
    end

    test "correctly updates pid-based bindings when the stopped non-ephemeral child is not restarted" do
      Parent.initialize()

      child1 =
        start_child!(
          id: :child1,
          restart: :temporary,
          start: {Task, :start_link, [fn -> :ok end]}
        )

      start_child!(id: :child2, binds_to: [child1])
      start_child!(id: :child3, binds_to: [child1])

      :ignore = handle_parent_message()

      {:ok, stopped_children} = Parent.shutdown_child(:child1)
      assert Map.keys(stopped_children) == [:child1, :child2, :child3]
    end
  end

  describe "shutdown_all/1" do
    test "terminates all children in the opposite startup order irrespective of bindings" do
      Parent.initialize()

      child1 = start_child!(id: :child1, group: :group1)
      Process.monitor(child1)

      child2 = start_child!(id: :child2)
      Process.monitor(child2)

      child3 = start_child!(id: :child3, group: :group1)
      Process.monitor(child3)

      Parent.shutdown_all()
      refute_receive {:EXIT, _pid, _reason}

      assert_receive {:DOWN, _mref, :process, pid1, _reason}
      assert_receive {:DOWN, _mref, :process, pid2, _reason}
      assert_receive {:DOWN, _mref, :process, pid3, _reason}

      assert [pid1, pid2, pid3] == [child3, child2, child1]
    end

    test "returns stopped_children that can be passed to return_children/1" do
      Parent.initialize()

      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)

      stopped_children = Parent.shutdown_all()
      assert Parent.return_children(stopped_children) == :ok
      assert Enum.map(Parent.children(), & &1.id) == ~w/child1 child2 child3/a
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.shutdown_all/0
    end
  end

  describe "children/0" do
    test "returns child processes" do
      Parent.initialize()
      assert Parent.children() == []

      child1 = start_child!(id: :child1, meta: :meta1)
      assert Parent.children() == [%{id: :child1, pid: child1, meta: :meta1}]

      child2 = start_child!(id: :child2, meta: :meta2)

      assert Parent.children() == [
               %{id: :child1, pid: child1, meta: :meta1},
               %{id: :child2, pid: child2, meta: :meta2}
             ]

      Parent.shutdown_child(:child1)
      assert Parent.children() == [%{id: :child2, pid: child2, meta: :meta2}]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.children/0
    end
  end

  describe "num_children/0" do
    test "returns the number of child processes" do
      Parent.initialize()
      assert Parent.num_children() == 0

      start_child!(id: :child1)
      assert Parent.num_children() == 1

      start_child!()
      assert Parent.num_children() == 2

      Parent.shutdown_child(:child1)
      assert Parent.num_children() == 1
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.num_children/0
    end
  end

  describe "child?/0" do
    test "returns true for known children, false otherwise" do
      Parent.initialize()

      refute Parent.child?(:child1)
      refute Parent.child?(:child2)

      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.child?(:child1)
      assert Parent.child?(child1)

      assert Parent.child?(:child2)
      assert Parent.child?(child2)

      Parent.shutdown_child(:child1)
      refute Parent.child?(:child1)
      refute Parent.child?(child1)

      assert Parent.child?(:child2)
      assert Parent.child?(child2)
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child?(:foo) end
    end
  end

  describe "child_pid/1" do
    test "returns the pid of the given child, error otherwise" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.child_pid(:child1) == {:ok, child1}
      assert Parent.child_pid(:child2) == {:ok, child2}
      assert Parent.child_pid(:unknown_child) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_pid(:child1) == :error
      assert Parent.child_pid(:child2) == {:ok, child2}
    end

    test "can be invoked while the chid is being started" do
      Parent.initialize()
      test_pid = self()

      child1 = start_child!(id: :child1)

      start_child!(
        start: fn ->
          send(test_pid, {:child1, Parent.child_pid(:child1)})
          Agent.start_link(fn -> :ok end)
        end
      )

      assert_receive {:child1, {:ok, ^child1}}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_pid(:foo) end
    end
  end

  describe "child_id/1" do
    test "returns the id of the given child, error otherwise" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.child_id(child1) == {:ok, :child1}
      assert Parent.child_id(child2) == {:ok, :child2}
      assert Parent.child_id(self()) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_id(child1) == :error
      assert Parent.child_id(child2) == {:ok, :child2}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_id(self()) end
    end
  end

  describe "child_meta/1" do
    test "returns the meta of the given child, error otherwise" do
      Parent.initialize()

      child1 = start_child!(id: :child1, meta: :meta1)
      child2 = start_child!(id: :child2, meta: :meta2)

      assert Parent.child_meta(:child1) == {:ok, :meta1}
      assert Parent.child_meta(child1) == {:ok, :meta1}

      assert Parent.child_meta(:child2) == {:ok, :meta2}
      assert Parent.child_meta(child2) == {:ok, :meta2}

      assert Parent.child_meta(:unknown_child) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_meta(:child1) == :error
      assert Parent.child_meta(:child2) == {:ok, :meta2}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_meta(:child) end
    end
  end

  describe "update_child_meta/2" do
    test "updates meta of the known child, fails otherwise" do
      Parent.initialize()

      start_child!(id: :child1, meta: 1)
      child2 = start_child!(id: :child2, meta: 2)

      Parent.update_child_meta(:child2, &(&1 + 1))
      Parent.update_child_meta(child2, &(&1 + 1))

      assert Parent.child_meta(:child1) == {:ok, 1}
      assert Parent.child_meta(:child2) == {:ok, 4}

      Parent.shutdown_child(:child1)
      assert Parent.update_child_meta(:child1, & &1) == :error
    end

    test "updates meta in registry, fails otherwise" do
      Parent.initialize(registry?: true)
      start_child!(id: :child1, meta: 1)
      Parent.update_child_meta(:child1, &(&1 + 1))
      assert Parent.Client.child_meta(self(), :child1) == {:ok, 2}
    end

    test "doesn't affect meta of a reset child" do
      Parent.initialize()

      start_child!(id: :child, meta: 1)
      Parent.update_child_meta(:child, &(&1 + 1))
      provoke_child_termination!(:child)

      assert Parent.child_meta(:child) == {:ok, 1}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.update_child_meta(:child, & &1)
      end
    end
  end

  describe "handle_message/1" do
    test "handles child termination" do
      Parent.initialize()
      child1 = start_child!(id: :child1, meta: :meta, restart: :temporary, ephemeral?: false)
      child2 = start_child!(id: :child2, meta: :meta, restart: :temporary, ephemeral?: true)

      GenServer.stop(child1)
      assert handle_parent_message() == :ignore
      assert Parent.child?(:child1)
      assert child_pid!(:child1) == :undefined

      GenServer.stop(child2)
      assert {:stopped_children, %{child2: _}} = handle_parent_message()
      refute Parent.child?(:child2)
    end

    test "terminates dependencies if a child stops" do
      Parent.initialize()

      {:ok, child1} = start_child(id: :child1, restart: :transient)
      {:ok, child2} = start_child(id: :child2, restart: :temporary, binds_to: [:child1])
      {:ok, child3} = start_child(id: :child3, restart: :temporary, binds_to: [:child1])
      {:ok, child4} = start_child(id: :child4, restart: :temporary)

      Enum.each([child2, child3], &Process.monitor/1)

      GenServer.stop(child1)

      assert handle_parent_message() == :ignore

      assert Enum.map(Parent.children(), &{&1.id, &1.pid}) == [
               child1: :undefined,
               child2: :undefined,
               child3: :undefined,
               child4: child4
             ]

      assert_receive {:DOWN, _mref, :process, pid1, :shutdown}
      assert_receive {:DOWN, _mref, :process, pid2, :shutdown}
      assert [pid1, pid2] == [child3, child2]
    end

    test "handles child timeout by stopping the child" do
      Parent.initialize()
      start_child!(id: :child, restart: :temporary, meta: :meta, timeout: 0)
      handle_parent_message()
      assert Parent.child_pid(:child) == {:ok, :undefined}
    end

    test "handles supervisor calls" do
      Parent.initialize()
      parent = self()
      child = start_child!(id: :child)

      task =
        Task.async(fn ->
          assert :supervisor.which_children(parent) == [{:child, child, :worker, [Agent]}]

          assert :supervisor.count_children(parent) ==
                   [active: 1, specs: 1, supervisors: 0, workers: 1]

          assert {:ok, %{id: :child}} = :supervisor.get_childspec(parent, :child)
          assert {:ok, %{id: :child}} = :supervisor.get_childspec(parent, child)
          assert :supervisor.get_childspec(parent, :unknown_child) == {:error, :not_found}
        end)

      assert handle_parent_message() == :ignore
      assert handle_parent_message() == :ignore
      assert handle_parent_message() == :ignore
      assert handle_parent_message() == :ignore
      assert handle_parent_message() == :ignore

      Task.await(task)
    end

    test "which_children correctly handles anonymous children" do
      Parent.initialize()
      parent = self()
      child1 = start_child!()
      child2 = start_child!(id: :child)
      child3 = start_child!()

      task =
        Task.async(fn ->
          assert :supervisor.which_children(parent) == [
                   {:undefined, child1, :worker, [Agent]},
                   {:child, child2, :worker, [Agent]},
                   {:undefined, child3, :worker, [Agent]}
                 ]
        end)

      assert handle_parent_message() == :ignore

      Task.await(task)
    end

    test "ignores unknown messages" do
      Parent.initialize()
      assert is_nil(Parent.handle_message({:EXIT, self(), :normal}))
      assert is_nil(Parent.handle_message(:unknown_message))
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.handle_message(:foo)
      end
    end
  end

  describe "return_children/1" do
    test "starts all stopped children preserving the shutdown order" do
      Parent.initialize()
      start_child!(id: :child1)
      child2 = start_child!(id: :child2)
      start_child!(id: :child3, binds_to: [:child1])
      {:ok, stopped_children} = Parent.shutdown_child(:child1)

      assert Parent.return_children(stopped_children) == :ok

      assert [
               %{id: :child1, pid: child1},
               %{id: :child2, pid: ^child2},
               %{id: :child3, pid: child3}
             ] = Parent.children()

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)

      Parent.shutdown_all()

      assert_receive {:DOWN, _mref, :process, pid1, _reason}
      assert_receive {:DOWN, _mref, :process, pid2, _reason}
      assert_receive {:DOWN, _mref, :process, pid3, _reason}

      assert [pid1, pid2, pid3] == [child3, child2, child1]
    end

    test "tries to restart non-started processes automatically" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [child1])
      child3 = start_child!(id: :child3, binds_to: [child1], shutdown_group: :group1)
      start_child!(id: :child4, shutdown_group: :group1)
      start_child!(id: :child5, binds_to: [child3])
      start_child!(id: :child6, binds_to: [:child5], shutdown_group: :group1)

      # running this multiple times to make sure all bindings are correctly preserved
      for _ <- 1..5 do
        {:ok, stopped_children} = Parent.shutdown_child(:child1)

        raise_on_child_start(:child5)
        assert Parent.return_children(stopped_children) == :ok
        assert_receive {:EXIT, _failed_child5, _}

        assert Enum.map(Parent.children(), & &1.id) ==
                 ~w/child1 child2 child3 child4 child5 child6/a

        Enum.each(~w/child1 child2/a, &assert(is_pid(child_pid!(&1))))
        Enum.each(~w/child3 child4 child5 child6/a, &assert(child_pid!(&1) == :undefined))

        succeed_on_child_start(:child5)
        assert handle_parent_message() == :ignore

        Enum.each(~w/child3 child4 child5 child6/a, &assert(is_pid(child_pid!(&1))))
      end
    end

    test "treats failed start of an ephemeral temporary child as a crash" do
      Parent.initialize()

      start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1], restart: :temporary, ephemeral?: true)
      start_child!(id: :child3, shutdown_group: :group1)
      start_child!(id: :child4, shutdown_group: :group1, binds_to: [:child2])
      start_child!(id: :child5, binds_to: [:child1])

      {:ok, stopped_children} = Parent.shutdown_child(:child1)

      raise_on_child_start(:child2)
      assert Parent.return_children(stopped_children) == :ok
      assert_receive {:EXIT, _, _}

      assert Enum.map(Parent.children(), & &1.id) == ~w/child1 child5/a

      assert {:stopped_children, stopped_children} = handle_parent_message()
      assert Map.keys(stopped_children) == ~w/child2 child3 child4/a
    end

    test "treats failed start of a non-ephemeral temporary child as a crash" do
      Parent.initialize()

      start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1], restart: :temporary, ephemeral?: false)
      start_child!(id: :child3, shutdown_group: :group1)
      start_child!(id: :child4, shutdown_group: :group1, binds_to: [:child2])
      start_child!(id: :child5, binds_to: [:child1])

      {:ok, stopped_children} = Parent.shutdown_child(:child1)

      raise_on_child_start(:child2)
      assert Parent.return_children(stopped_children) == :ok
      assert_receive {:EXIT, _, _}

      assert Enum.map(Parent.children(), & &1.id) == ~w/child1 child2 child3 child4 child5/a
      Enum.each(~w/child2 child3 child4/a, &assert(Parent.child_pid(&1) == {:ok, :undefined}))
    end

    test "is idempotent" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1])
      {:ok, stopped_children} = Parent.shutdown_child(:child1)
      assert Parent.return_children(stopped_children) == :ok
      assert Parent.return_children(stopped_children) == :ok
      assert [%{id: :child1}, %{id: :child2}] = Parent.children()
    end

    test "records restart of a terminated child" do
      Parent.initialize()
      start_child!(id: :child1, restart: :temporary)
      start_child!(id: :child2)

      start_child!(
        id: :child3,
        binds_to: [:child1],
        restart: :temporary,
        ephemeral?: true,
        max_restarts: 1
      )

      {:stopped_children, stopped_children} = provoke_child_termination!(:child3, at: 0)
      Parent.return_children(stopped_children)

      {:stopped_children, stopped_children} = provoke_child_termination!(:child3, at: 0)

      log =
        assert_parent_exit(
          fn -> Parent.return_children(stopped_children) end,
          :too_many_restarts
        )

      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "correctly returns pid-references dependencies" do
      Parent.initialize()

      child1 = start_child!(shutdown_group: :group1)
      child2 = start_child!(binds_to: [child1])
      start_child!(binds_to: [child2])
      start_child!(shutdown_group: :group1)
      start_child!(binds_to: [child1])
      child6 = start_child!()

      {:ok, stopped_children} = Parent.shutdown_child(child1)
      Parent.return_children(stopped_children)
      assert Parent.num_children() == 6

      Parent.shutdown_child(hd(Parent.children()).pid)
      assert [%{pid: ^child6}] = Parent.children()
    end
  end

  defp handle_parent_message,
    do: Parent.handle_message(assert_receive _message)

  defp provoke_child_termination!(child_id, opts \\ []) do
    now_ms = Keyword.get(opts, :at, 0)
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn -> now_ms end)
    {:ok, pid} = Parent.child_pid(child_id)
    Process.exit(pid, Keyword.get(opts, :reason, :shutdown))
    handle_parent_message()
  end

  defp assert_parent_exit(fun, exit_reason) do
    log = capture_log(fn -> assert catch_exit(fun.()) == exit_reason end)
    assert_receive {:EXIT, _string_io_pid, :normal}
    log
  end

  defp start_child(overrides \\ []) do
    overrides = Map.new(overrides)
    id = Map.get(overrides, :id, nil)
    succeed_on_child_start(id)

    Parent.start_child(
      %{
        id: id,
        start:
          {Agent, :start_link,
           [fn -> if id && :ets.lookup(__MODULE__, id) == [{id, true}], do: raise("error") end]}
      },
      overrides
    )
  end

  defp start_child!(overrides \\ []) do
    {:ok, pid} = start_child(overrides)
    pid
  end

  defp child_pid!(child_id) do
    {:ok, pid} = Parent.child_pid(child_id)
    pid
  end

  def succeed_on_child_start(id), do: :ets.insert(__MODULE__, {id, false})
  def raise_on_child_start(id), do: :ets.insert(__MODULE__, {id, true})
end
