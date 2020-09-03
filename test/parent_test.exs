defmodule ParentTest do
  use ExUnit.Case, async: true

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

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

    test "accepts module as a single argument" do
      Parent.initialize()
      assert {:ok, _child} = Parent.start_child(TestChild)
    end

    test "accepts a child specification map" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: {TestChild, :start_link, []}})
    end

    test "accepts a zero arity function in the :start key of the child spec" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: fn -> TestChild.start_link() end})
    end

    test "succeeds if deps are started" do
      Parent.initialize()
      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)
      assert {:ok, _pid} = TestChild.start(binds_to: ~w/child1 child2/a)
    end

    test "fails if the process fails to start" do
      Parent.initialize()
      assert Parent.start_child({TestChild, init: fn _ -> :ignore end}) == :ignore

      assert Parent.start_child({TestChild, init: fn _ -> {:stop, :some_reason} end}) ==
               {:error, :some_reason}
    end

    test "fails if the id is already taken" do
      Parent.initialize()
      child = TestChild.start!(id: :child)
      assert TestChild.start(id: :child) == {:error, {:already_started, child}}
    end

    test "fails if deps are not started" do
      Parent.initialize()
      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)

      assert {:error, error} = TestChild.start(binds_to: ~w/child1 child2 child4 child5/a)
      assert error == {:missing_deps, ~w/child4 child5/a}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &TestChild.start/0
    end
  end

  describe "shutdown_child/1" do
    test "stops the child synchronously, handling the exit message" do
      Parent.initialize()
      child = TestChild.start!(id: :child)
      Parent.shutdown_child(:child)

      refute Process.alive?(child)
      refute_receive {:EXIT, ^child, _reason}
    end

    test "forcefully terminates the child if shutdown is `:brutal_kill`" do
      Parent.initialize()

      child =
        TestChild.start!(
          [id: :child, shutdown: :brutal_kill],
          block_terminate?: true,
          trap_exit?: true
        )

      Process.monitor(child)
      Parent.shutdown_child(:child)
      assert_receive {:DOWN, _mref, :process, ^child, :killed}
    end

    test "forcefully terminates a child if it doesn't stop in the given time" do
      Parent.initialize()

      child =
        TestChild.start!(
          [id: :child, shutdown: 10],
          block_terminate?: true,
          trap_exit?: true
        )

      Process.monitor(child)
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
      child1 = TestChild.start!(id: :child1)
      child2 = TestChild.start!(id: :child2, binds_to: [:child1])
      child3 = TestChild.start!(id: :child3, binds_to: [:child2])
      _child4 = TestChild.start!(id: :child4)

      Enum.each([child1, child2, child3], &Process.monitor/1)
      Parent.shutdown_child(:child1)

      assert [%{id: :child4}] = Parent.children()

      assert_receive {:DOWN, _mref, :process, pid1, _reason}
      assert_receive {:DOWN, _mref, :process, pid2, _reason}
      assert_receive {:DOWN, _mref, :process, pid3, _reason}

      assert [pid1, pid2, pid3] == [child3, child2, child1]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.shutdown_child(1) end
    end
  end

  describe "restart_child" do
    test "restarts the process and returns the new pid" do
      Parent.initialize()
      child = TestChild.start!(id: :child)
      assert Parent.restart_child(:child) == %{also_restarted: [], also_terminated: []}
      {:ok, new_pid} = Parent.child_pid(:child)
      refute new_pid == child
    end

    test "fails if the process fails to start" do
      Parent.initialize()

      key = make_ref()
      :persistent_term.put(key, false)
      fun = fn -> if :persistent_term.get(key), do: raise("error") end
      start = {Agent, :start_link, [fun]}

      TestChild.start!(id: :child, start: start)

      :persistent_term.put(key, true)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(Parent.restart_child(:child)) == :restart_error
      end)
    end

    test "preserves startup order" do
      Parent.initialize()
      child1 = TestChild.start!(id: :child1)
      _child2 = TestChild.start!(id: :child2)
      child3 = TestChild.start!(id: :child3)

      Parent.restart_child(:child2)
      {:ok, child2} = Parent.child_pid(:child2)
      assert Enum.map(Parent.children(), & &1.pid) == [child1, child2, child3]
    end

    test "also restarts non-temporary dependees" do
      Parent.initialize()

      child1 = TestChild.start!(id: :child1)
      child2 = TestChild.start!(id: :child2, binds_to: [:child1])
      child3 = TestChild.start!(id: :child3, restart: :temporary, binds_to: [:child2])
      child4 = TestChild.start!(id: :child4)

      Process.monitor(child2)
      %{also_terminated: terminated, also_restarted: restarted} = Parent.restart_child(:child1)

      assert terminated == [%{id: :child3, meta: nil, pid: child3}]
      assert restarted == [:child2]

      assert [
               %{id: :child1, meta: nil, pid: new_child1},
               %{id: :child2, meta: nil, pid: new_child2},
               %{id: :child4, meta: nil, pid: ^child4}
             ] = Parent.children()

      refute new_child1 == child1
      refute new_child2 == child2
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.restart_child(1) end
    end
  end

  describe "automatic child restart" do
    test "is performed when a permanent child terminates" do
      Parent.initialize()
      pid1 = TestChild.start!(id: :child, meta: :meta)
      restart_info = provoke_child_restart!(:child, restart: :shutdown)

      assert restart_info.id == :child
      assert restart_info.reason == :shutdown
      assert [%{id: :child, meta: :meta, pid: pid2}] = Parent.children()
      refute pid2 == pid1
    end

    test "is performed when a transient child terminates abnormally" do
      Parent.initialize()
      TestChild.start!(id: :child, restart: :transient)
      provoke_child_restart!(:child)
      assert Parent.child?(:child)
    end

    test "is performed when a child is terminated due to a timeout" do
      Parent.initialize()
      TestChild.start!(id: :child, timeout: 0)

      assert {:child_restarted, restart_info} = handle_parent_message()
      assert restart_info.id == :child
      assert restart_info.reason == :timeout
      assert Parent.child?(:child)
    end

    test "is performed when :restart option is not provided" do
      Parent.initialize()
      TestChild.start!(id: :child)
      provoke_child_restart!(:child)
      assert Parent.child?(:child)
    end

    test "is not performed when a temporary child terminates" do
      Parent.initialize()
      child = TestChild.start!(id: :child, restart: :temporary)
      Process.exit(child, :kill)

      refute match?({:child_restarted, _restart_info}, handle_parent_message())
      refute Parent.child?(:child)
    end

    test "is not performed when a child is terminated via `Parent` function" do
      Parent.initialize()
      TestChild.start!(id: :child)
      Parent.shutdown_child(:child)

      refute_receive _
      refute Parent.child?(:child)
    end

    test "preserves startup order" do
      Parent.initialize()
      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)
      TestChild.start!(id: :child3)
      provoke_child_restart!(:child2)
      assert Enum.map(Parent.children(), & &1.id) == [:child1, :child2, :child3]
    end

    test "takes down the entire parent if the new instance fails to start" do
      Parent.initialize()

      key = make_ref()
      :persistent_term.put(key, false)
      fun = fn -> if :persistent_term.get(key), do: raise("error") end
      start = {Agent, :start_link, [fun]}

      child = TestChild.start!(id: :child, start: start)

      :persistent_term.put(key, true)
      Process.exit(child, :kill)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert catch_exit(handle_parent_message()) == :restart_error
        end)

      assert log =~ "[error] Failed to restart child :child"
      assert Parent.children() == []
    end

    test "also restarts non-temporary dependees" do
      Parent.initialize()

      child1 = TestChild.start!(id: :child1)
      child2 = TestChild.start!(id: :child2, binds_to: [:child1])
      child3 = TestChild.start!(id: :child3, restart: :temporary, binds_to: [:child2])
      child4 = TestChild.start!(id: :child4)

      Process.monitor(child2)
      restart_info = provoke_child_restart!(:child1)

      assert restart_info.also_restarted == [:child2]
      assert restart_info.also_terminated == [%{id: :child3, meta: nil, pid: child3}]

      assert [
               %{id: :child1, meta: nil, pid: new_child1},
               %{id: :child2, meta: nil, pid: new_child2},
               %{id: :child4, meta: nil, pid: ^child4}
             ] = Parent.children()

      refute new_child1 == child1
      refute new_child2 == child2
    end

    test "takes down the entire parent on too many global restarts" do
      Parent.initialize(max_restarts: 2)

      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)
      TestChild.start!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)

      log = assert_parent_exit(fn -> provoke_child_restart!(:child3) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "default restart limit is 3 restarts in 5 seconds" do
      Parent.initialize(max_restarts: 2)

      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)
      TestChild.start!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)

      log =
        assert_parent_exit(
          fn -> provoke_child_restart!(:child3, at: 4999) end,
          :too_many_restarts
        )

      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []

      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)
      TestChild.start!(id: :child3)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child2)
      provoke_child_restart!(:child3, at: 5000)
    end

    test "takes down the entire parent on too many restarts of a single child" do
      Parent.initialize(max_restarts: :infinity)

      TestChild.start!(id: :child1, restart: {:permanent, max_restarts: 2, max_seconds: 1})
      TestChild.start!(id: :child2)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)

      log = assert_parent_exit(fn -> provoke_child_restart!(:child1) end, :too_many_restarts)
      assert log =~ "[error] Too many restarts in parent process"
      assert Parent.children() == []
    end

    test "doesn't stop parent if max_restarts of the child is infinity" do
      Parent.initialize(max_restarts: :infinity)
      TestChild.start!(id: :child1, restart: {:permanent, max_restarts: :infinity})

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
    end

    test "default max_restarts of a child is infinity" do
      Parent.initialize(max_restarts: :infinity)
      TestChild.start!(id: :child1)

      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
      provoke_child_restart!(:child1)
    end

    test "clears recorded restarts after the interval has passed" do
      Parent.initialize()

      TestChild.start!(id: :child1, restart: {:permanent, max_restarts: 2, max_seconds: 2})
      TestChild.start!(id: :child2)

      provoke_child_restart!(:child1, at: :timer.seconds(0))
      provoke_child_restart!(:child1, at: :timer.seconds(1))
      provoke_child_restart!(:child1, at: :timer.seconds(2))
    end
  end

  describe "shutdown_all/1" do
    test "terminates all children in the opposite startup order" do
      Parent.initialize()

      child1 = TestChild.start!(id: :child1)
      Process.monitor(child1)

      child2 = TestChild.start!(id: :child2)
      Process.monitor(child2)

      Parent.shutdown_all()
      refute_receive {:EXIT, _pid, _reason}

      assert_receive {:DOWN, _mref, :process, pid1, _reason}
      assert_receive {:DOWN, _mref, :process, pid2, _reason}

      assert [pid1, pid2] == [child2, child1]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.shutdown_all/0
    end
  end

  describe "await_child_termination/1" do
    test "waits for the child to stop" do
      Parent.initialize()

      child = TestChild.start!(id: :child, meta: :meta)

      Task.start_link(fn ->
        Process.sleep(50)
        GenServer.stop(child)
      end)

      assert Parent.await_child_termination(:child, 1000) == {child, :meta, :normal}
      refute Process.alive?(child)
    end

    test "returns timeout if the child didn't stop" do
      Parent.initialize()
      child = TestChild.start!(id: :child, meta: :meta)
      assert Parent.await_child_termination(:child, 0) == :timeout
      assert Process.alive?(child)
    end

    test "raises if unknown child is given" do
      Parent.initialize()

      assert_raise RuntimeError, "unknown child", fn ->
        Parent.await_child_termination(:child, 1000)
      end
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.await_child_termination(:foo, :infinity)
      end
    end
  end

  describe "children/0" do
    test "returns child processes" do
      Parent.initialize()
      assert Parent.children() == []

      child1 = TestChild.start!(id: :child1, meta: :meta1)
      assert Parent.children() == [%{id: :child1, pid: child1, meta: :meta1}]

      child2 = TestChild.start!(id: :child2, meta: :meta2)

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

      TestChild.start!(id: :child1)
      assert Parent.num_children() == 1

      TestChild.start!()
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

      TestChild.start!(id: :child1)
      TestChild.start!(id: :child2)

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

      child1 = TestChild.start!(id: :child1)
      child2 = TestChild.start!(id: :child2)

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

      child1 = TestChild.start!(id: :child1)
      child2 = TestChild.start!(id: :child2)

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

      TestChild.start!(id: :child1, meta: :meta1)
      TestChild.start!(id: :child2, meta: :meta2)

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

      TestChild.start!(id: :child1, meta: 1)
      TestChild.start!(id: :child2, meta: 2)

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
      child = TestChild.start!(id: :child, meta: :meta, restart: :temporary)
      GenServer.stop(child)

      assert handle_parent_message() ==
               {:child_terminated,
                %{id: :child, meta: :meta, pid: child, reason: :normal, also_terminated: []}}

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
    end

    test "terminates dependencies if a child stops" do
      Parent.initialize()

      {:ok, child1} = TestChild.start(id: :child1, restart: :temporary)
      {:ok, child2} = TestChild.start(id: :child2, restart: :temporary, binds_to: [:child1])
      {:ok, child3} = TestChild.start(id: :child3, restart: :temporary, binds_to: [:child2])
      {:ok, _child4} = TestChild.start(id: :child4, restart: :temporary)

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
      child = TestChild.start!(id: :child, restart: :temporary, meta: :meta, timeout: 0)

      assert handle_parent_message() ==
               {:child_terminated,
                %{id: :child, meta: :meta, pid: child, reason: :timeout, also_terminated: []}}

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
    end

    test "handles supervisor calls" do
      Parent.initialize()
      parent = self()
      child = TestChild.start!(id: :child)

      task =
        Task.async(fn ->
          assert :supervisor.which_children(parent) == [{:child, child, :worker, [TestChild]}]

          assert :supervisor.count_children(parent) ==
                   [active: 1, specs: 1, supervisors: 0, workers: 1]
        end)

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
    test "finds registered children" do
      Parent.initialize()
      child1 = TestChild.start!(id: :child1, register?: true)
      TestChild.start!(id: :child2)
      TestChild.start!(id: :child3, register?: false)

      assert Parent.whereis_child(self(), :child1) == child1
      assert is_nil(Parent.whereis_child(self(), :child2))
      assert is_nil(Parent.whereis_child(self(), :child3))
    end

    test "finds the child inside its parent" do
      {parent1, [parent1_child]} = start_parent([[id: :child, register?: true]])
      {parent2, [parent2_child]} = start_parent([[id: :child, register?: true]])

      assert Parent.whereis_child(parent1, :child) == parent1_child
      assert Parent.whereis_child(parent2, :child) == parent2_child
    end

    test "can dereference aliases" do
      Parent.initialize()
      child1 = TestChild.start!(id: :child1, register?: true)

      registered_name = :"alias_#{System.unique_integer([:positive, :monotonic])}"
      Process.register(self(), registered_name)
      :global.register_name(registered_name, self())

      assert Parent.whereis_child(registered_name, :child1) == child1
      assert Parent.whereis_child({:global, registered_name}, :child1) == child1
      assert Parent.whereis_child({:via, :global, registered_name}, :child1) == child1
    end

    test "removes registered child after it terminates" do
      Parent.initialize()
      TestChild.start!(id: :child, register?: true)
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

  defp handle_parent_message,
    do: Parent.handle_message(assert_receive message)

  defp provoke_child_restart!(child_id, opts \\ []) do
    now_ms = Keyword.get(opts, :at, 0)
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn -> now_ms end)
    {:ok, pid} = Parent.child_pid(child_id)
    Process.exit(pid, Keyword.get(opts, :reason, :shutdown))
    {:child_restarted, restart_info} = handle_parent_message()
    restart_info
  end

  defp assert_parent_exit(fun, exit_reason) do
    log = ExUnit.CaptureLog.capture_log(fn -> assert catch_exit(fun.()) == exit_reason end)
    assert_receive {:EXIT, _string_io_pid, :normal}
    log
  end

  defp start_parent(child_specs) do
    test_pid = self()

    parent_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             Parent.initialize()
             children = Enum.map(child_specs, &TestChild.start!/1)
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
