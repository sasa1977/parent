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

    test "handles :ignore by the started process" do
      Parent.initialize()
      assert start_child(start: fn -> :ignore end) == {:ok, :undefined}
    end

    test "handles error by the started process" do
      Parent.initialize()
      assert start_child(start: fn -> {:error, :some_reason} end) == {:error, :some_reason}
    end

    test "fails if the id is already taken" do
      Parent.initialize()
      child = start_child!(id: :child)
      assert start_child(id: :child) == {:error, {:already_started, child}}
    end

    test "fails if deps are not started" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2)

      assert {:error, error} = start_child(binds_to: ~w/child1 child2 child4 child5/a)
      assert error == {:missing_deps, ~w/child4 child5/a}
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
                 Supervisor.child_spec({Agent, fn -> :ok end}, id: :child1),
                 %{id: :child2, start: fn -> :ignore end},
                 Supervisor.child_spec({Agent, fn -> :ok end}, id: :child3)
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

      assert Map.delete(Parent.shutdown_child(:child), :return_info) ==
               %{terminated_children: [:child]}

      refute Process.alive?(child)
      refute_receive {:EXIT, ^child, _reason}
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

    test "fails if an unknown child is given" do
      Parent.initialize()

      assert_raise RuntimeError, "trying to terminate an unknown child", fn ->
        Parent.shutdown_child(:child)
      end
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

      assert Parent.shutdown_child(:child4).terminated_children ==
               ~w/child1 child2 child3 child4 child5/a

      assert [%{id: :child6}] = Parent.children()

      pids =
        Enum.map(1..5, fn _ ->
          assert_receive {:DOWN, _mref, :process, pid, _reason}
          pid
        end)

      assert pids == [child5, child4, child3, child2, child1]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.shutdown_child(1) end
    end
  end

  describe "restart_child" do
    test "restarts the process and returns the new pid" do
      Parent.initialize()
      child = start_child!(id: :child)
      Parent.restart_child(:child)
      refute child_pid!(:child) == child
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

    test "also restarts bound siblings" do
      Parent.initialize()

      child1 = start_child!(id: :child1, shutdown_group: :group1)
      child2 = start_child!(id: :child2, binds_to: [:child1], shutdown_group: :group2)
      child3 = start_child!(id: :child3, binds_to: [:child2])
      child4 = start_child!(id: :child4, shutdown_group: :group1)
      child5 = start_child!(id: :child5, shutdown_group: :group2)
      child6 = start_child!(id: :child6)

      Parent.restart_child(:child4)

      refute child_pid!(:child1) == child1
      refute child_pid!(:child2) == child2
      refute child_pid!(:child3) == child3
      refute child_pid!(:child4) == child4
      refute child_pid!(:child5) == child5
      assert child_pid!(:child6) == child6
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.restart_child(1) end
    end
  end

  describe "automatic child restart" do
    test "is performed when a permanent child terminates" do
      Parent.initialize()
      pid1 = start_child!(id: :child, meta: :meta)
      provoke_child_restart!(:child, restart: :shutdown)
      refute child_pid!(:child) == pid1
    end

    test "is performed when a transient child terminates abnormally" do
      Parent.initialize()
      start_child!(id: :child, restart: :transient)
      provoke_child_restart!(:child)
      assert Parent.child?(:child)
    end

    test "is performed when a child is terminated due to a timeout" do
      Parent.initialize()
      start_child!(id: :child, timeout: 0)
      :ignore = handle_parent_message()
      assert Parent.child?(:child)
    end

    test "is performed when :restart option is not provided" do
      Parent.initialize()
      start_child!(id: :child)
      provoke_child_restart!(:child)
      assert Parent.child?(:child)
    end

    test "is not performed when a temporary child terminates" do
      Parent.initialize()
      child = start_child!(id: :child, restart: :temporary)
      Process.exit(child, :kill)

      refute match?({:child_restarted, _restart_info}, handle_parent_message())
      refute Parent.child?(:child)
    end

    test "is not performed when a child is terminated via `Parent` function" do
      Parent.initialize()
      start_child!(id: :child)
      Parent.shutdown_child(:child)

      refute_receive _
      refute Parent.child?(:child)
    end

    test "preserves startup order" do
      Parent.initialize()
      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)
      provoke_child_restart!(:child2)
      assert Enum.map(Parent.children(), & &1.id) == [:child1, :child2, :child3]
    end

    test "gradually retries child restart if the child fails to start" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      start_child!(id: :child2, binds_to: [:child1])

      raise_on_child_start(:child1)
      Process.exit(child1, :kill)

      assert handle_parent_message() == :ignore
      assert Parent.children() == []
      assert_receive {:EXIT, pid, _}

      succeed_on_child_start(:child1)
      raise_on_child_start(:child2)

      assert handle_parent_message() == :ignore
      assert [%{id: :child1}] = Parent.children()
      assert_receive {:EXIT, pid, _}

      succeed_on_child_start(:child2)
      assert handle_parent_message() == :ignore
      assert [%{id: :child1}, %{id: :child2}] = Parent.children()
    end

    test "also restarts bound siblings" do
      Parent.initialize()

      child1 = start_child!(id: :child1, shutdown_group: :group1)
      child2 = start_child!(id: :child2, binds_to: [:child1], shutdown_group: :group2)
      child3 = start_child!(id: :child3, binds_to: [:child2])
      child4 = start_child!(id: :child4, shutdown_group: :group1)
      child5 = start_child!(id: :child5, shutdown_group: :group2)
      child6 = start_child!(id: :child6)

      provoke_child_restart!(:child4)

      refute child_pid!(:child1) == child1
      refute child_pid!(:child2) == child2
      refute child_pid!(:child3) == child3
      refute child_pid!(:child4) == child4
      refute child_pid!(:child5) == child5
      assert child_pid!(:child6) == child6
    end

    test "takes down the entire parent on too many global restarts" do
      Parent.initialize(max_restarts: 2)

      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)

      log = assert_parent_exit(fn -> provoke_child_restart!(:child3) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "default restart limit is 3 restarts in 5 seconds" do
      Parent.initialize(max_restarts: 2)

      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)

      log =
        assert_parent_exit(
          fn -> provoke_child_restart!(:child3, at: 4999) end,
          :too_many_restarts
        )

      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []

      start_child!(id: :child1)
      start_child!(id: :child2)
      start_child!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)
      provoke_child_restart!(:child3, at: 5000)
    end

    test "takes down the entire parent on too many restarts of a single child" do
      Parent.initialize(max_restarts: :infinity)

      start_child!(id: :child1, max_restarts: 2, max_seconds: 1)
      start_child!(id: :child2)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)

      log = assert_parent_exit(fn -> provoke_child_restart!(:child1) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "doesn't stop parent if max_restarts of the child is infinity" do
      Parent.initialize(max_restarts: :infinity)
      start_child!(id: :child1, max_restarts: :infinity)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
    end

    test "default max_restarts of a child is infinity" do
      Parent.initialize(max_restarts: :infinity)
      start_child!(id: :child1)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
    end

    test "clears recorded restarts after the interval has passed" do
      Parent.initialize()

      start_child!(id: :child1, max_restarts: 2, max_seconds: 2)
      start_child!(id: :child2)

      provoke_child_restart!(:child1, at: :timer.seconds(0))
      provoke_child_restart!(:child1, at: :timer.seconds(1))
      provoke_child_restart!(:child1, at: :timer.seconds(2))
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

      start_child!(id: :child1)
      start_child!(id: :child2)

      assert Parent.child?(:child1)
      assert Parent.child?(:child2)

      Parent.shutdown_child(:child1)
      refute Parent.child?(:child1)
      assert Parent.child?(:child2)
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

      start_child!(id: :child1, meta: :meta1)
      start_child!(id: :child2, meta: :meta2)

      assert Parent.child_meta(:child1) == {:ok, :meta1}
      assert Parent.child_meta(:child2) == {:ok, :meta2}
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
      start_child!(id: :child2, meta: 2)

      Parent.update_child_meta(:child2, &(&1 + 1))

      assert Parent.child_meta(:child1) == {:ok, 1}
      assert Parent.child_meta(:child2) == {:ok, 3}

      Parent.shutdown_child(:child1)
      assert Parent.update_child_meta(:child1, & &1) == :error
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
      child = start_child!(id: :child, meta: :meta, restart: :temporary)
      GenServer.stop(child)

      assert {:child_terminated, info} = handle_parent_message()

      assert Map.delete(info, :return_info) == %{
               id: :child,
               meta: :meta,
               pid: child,
               reason: :normal,
               also_terminated: []
             }

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
    end

    test "terminates dependencies if a child stops" do
      Parent.initialize()

      {:ok, child1} = start_child(id: :child1, restart: :transient)
      {:ok, child2} = start_child(id: :child2, restart: :temporary, binds_to: [:child1])
      {:ok, child3} = start_child(id: :child3, restart: :temporary, binds_to: [:child1])
      {:ok, _child4} = start_child(id: :child4, restart: :temporary)

      Enum.each([child2, child3], &Process.monitor/1)

      GenServer.stop(child1)

      assert {:child_terminated, info} = handle_parent_message()

      assert info.also_terminated == [
               %{id: :child2, meta: nil, pid: child2},
               %{id: :child3, meta: nil, pid: child3}
             ]

      assert Parent.num_children() == 1
      assert [%{id: :child4}] = Parent.children()

      assert_receive {:DOWN, _mref, :process, pid1, :shutdown}
      assert_receive {:DOWN, _mref, :process, pid2, :shutdown}
      assert [pid1, pid2] == [child3, child2]
    end

    test "handles child timeout by stopping the child" do
      Parent.initialize()
      child = start_child!(id: :child, restart: :temporary, meta: :meta, timeout: 0)

      assert {:child_terminated, info} = handle_parent_message()

      assert Map.delete(info, :return_info) == %{
               id: :child,
               meta: :meta,
               pid: child,
               reason: :timeout,
               also_terminated: []
             }

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
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

  describe "whereis_child/2" do
    test "finds registered children by id" do
      Parent.initialize(registry?: true)
      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.whereis_child(self(), :child1) == child1
      assert Parent.whereis_child(self(), :child2) == child2

      assert GenServer.whereis({:via, Parent, {self(), :child1}}) == child1
      assert GenServer.whereis({:via, Parent, {self(), :child2}}) == child2
    end

    test "finds registered children by roles" do
      Parent.initialize(registry?: true)
      child1 = start_child!(roles: [:foo, :bar])
      child2 = start_child!(roles: [:foo])
      start_child!(roles: [])
      start_child!()

      assert Parent.children_in_role(self(), :foo) == [child1, child2]
      assert Parent.children_in_role(self(), :bar) == [child1]
    end

    test "finds the child inside its parent" do
      {parent1, [parent1_child]} = start_parent([[id: :child]], registry?: true)
      {parent2, [parent2_child]} = start_parent([[id: :child]], registry?: true)

      assert Parent.whereis_child(parent1, :child) == parent1_child
      assert Parent.whereis_child(parent2, :child) == parent2_child
    end

    test "can dereference aliases" do
      Parent.initialize(registry?: true)
      child1 = start_child!(id: :child1)

      registered_name = :"alias_#{System.unique_integer([:positive, :monotonic])}"
      Process.register(self(), registered_name)
      :global.register_name(registered_name, self())

      assert Parent.whereis_child(registered_name, :child1) == child1
      assert Parent.whereis_child({:global, registered_name}, :child1) == child1
      assert Parent.whereis_child({:via, :global, registered_name}, :child1) == child1
    end

    test "removes registered child after it terminates" do
      Parent.initialize(registry?: true)
      start_child!(id: :child, roles: [:foo, :bar])
      Parent.shutdown_child(:child)

      assert is_nil(Parent.whereis_child(self(), :child))
      assert :ets.tab2list(Parent.MetaRegistry.table!(self())) == []
    end

    test "removes registered children after the parent terminates" do
      {parent, _children} = start_parent([[id: :child1], [id: :child2]])
      Process.monitor(parent)
      Process.exit(parent, :kill)
      assert_receive {:DOWN, _mref, :process, ^parent, _}
      assert is_nil(Parent.whereis_child(self(), :child1))
      assert is_nil(Parent.whereis_child(self(), :child2))
    end
  end

  describe "return_children/1" do
    test "starts all stopped children preserving the shutdown order" do
      Parent.initialize()
      start_child!(id: :child1)
      child2 = start_child!(id: :child2)
      start_child!(id: :child3, binds_to: [:child1])
      return_info = Parent.shutdown_child(:child1).return_info
      Parent.return_children(return_info)

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

    test "is idempotent" do
      Parent.initialize()
      start_child!(id: :child, restart: :temporary, max_restarts: 1)
      return_info = provoke_child_termination!(:child, at: 0).return_info
      Parent.return_children(return_info)
      Parent.return_children(return_info)
      assert [%{id: :child}] = Parent.children()
    end

    test "records restart of a terminated child" do
      Parent.initialize()
      start_child!(id: :child1, shutdown_group: :group1, restart: :temporary)
      start_child!(id: :child2)
      start_child!(id: :child3, shutdown_group: :group1, restart: :temporary, max_restarts: 1)

      return_info = provoke_child_termination!(:child3, at: 0).return_info
      Parent.return_children(return_info)

      return_info = provoke_child_termination!(:child3, at: 0).return_info

      log =
        assert_parent_exit(
          fn -> Parent.return_children(return_info) end,
          :too_many_restarts
        )

      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end
  end

  defp handle_parent_message,
    do: Parent.handle_message(assert_receive message)

  defp provoke_child_restart!(child_id, opts \\ []) do
    now_ms = Keyword.get(opts, :at, 0)
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn -> now_ms end)
    {:ok, pid} = Parent.child_pid(child_id)
    Process.exit(pid, Keyword.get(opts, :reason, :shutdown))
    :ignore = handle_parent_message()
    nil
  end

  defp provoke_child_termination!(child_id, opts) do
    now_ms = Keyword.get(opts, :at, 0)
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn -> now_ms end)
    {:ok, pid} = Parent.child_pid(child_id)
    Process.exit(pid, Keyword.get(opts, :reason, :shutdown))
    {:child_terminated, terminated_info} = handle_parent_message()
    terminated_info
  end

  defp assert_parent_exit(fun, exit_reason) do
    log = capture_log(fn -> assert catch_exit(fun.()) == exit_reason end)
    assert_receive {:EXIT, _string_io_pid, :normal}
    log
  end

  defp start_child(overrides \\ []) do
    id = Keyword.get(overrides, :id, make_ref())
    succeed_on_child_start(id)

    Parent.child_spec(
      %{
        id: id,
        start:
          {Agent, :start_link,
           [fn -> if :ets.lookup(__MODULE__, id) == [{id, true}], do: raise("error") end]}
      },
      overrides
    )
    |> Parent.start_child()
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

  defp start_parent(child_specs, parent_opts \\ []) do
    test_pid = self()

    parent_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             Parent.initialize(parent_opts)
             children = Enum.map(child_specs, &start_child!/1)
             send(test_pid, children)

             receive do
               _ -> :ok
             end
           end},
          id: make_ref()
        )
      )

    assert_receive children

    {parent_pid, children}
  end
end
