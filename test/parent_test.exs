defmodule ParentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Parent.ChildSpecGenerators

  test "shutting down a child which refuses to stop" do
    init()

    stubborn_child = %{
      id: :stubborn_child,
      start: fn ->
        Task.start_link(fn ->
          Process.flag(:trap_exit, true)
          Process.sleep(:infinity)
        end)
      end,
      shutdown: 100
    }

    normal_child = %{id: :normal_child, start: fn -> Agent.start_link(fn -> :ok end) end}

    {:ok, stubborn_pid} = Parent.start_child(stubborn_child)
    {:ok, normal_pid} = Parent.start_child(normal_child)

    Parent.shutdown_all(:shutdown)

    assert Parent.num_children() == 0
    refute Process.alive?(stubborn_pid)
    refute Process.alive?(normal_pid)
  end

  test "child timeout" do
    init()

    {:ok, child_pid} =
      Parent.start_child(%{
        id: :child,
        start: fn -> Agent.start_link(fn -> :ok end) end,
        timeout: 1,
        meta: :timeout_meta
      })

    assert_receive {Parent.State, :child_timeout, ^child_pid} = message
    assert Parent.handle_message(message) == {:EXIT, child_pid, :child, :timeout_meta, :timeout}
    assert Parent.num_children() == 0
    refute Process.alive?(child_pid)
  end

  test "awaits child termination" do
    init()

    child = %{id: :child, start: fn -> Task.start_link(fn -> :ok end) end, meta: :child_meta}
    {:ok, child_pid} = Parent.start_child(child)

    assert {^child_pid, :child_meta, :normal} = Parent.await_child_termination(:child, 1000)
    refute Process.alive?(child_pid)
    assert Parent.num_children() == 0
  end

  test "timeouts awaiting child termination" do
    init()

    child = %{id: :child, start: fn -> Agent.start_link(fn -> :ok end) end, meta: :child_meta}
    {:ok, child_pid} = Parent.start_child(child)

    assert Parent.await_child_termination(:child, 100) == :timeout
    assert Process.alive?(child_pid)
    assert Parent.num_children() == 1
    assert Parent.children() == [{:child, child_pid, :child_meta}]
  end

  test "supervisor calls are handled by `handle_message`" do
    parent = self()

    init()

    {:ok, child} =
      Parent.start_child(%{id: :child, start: fn -> Agent.start_link(fn -> :ok end) end})

    task =
      Task.async(fn ->
        assert :supervisor.which_children(parent) == [{:child, child, :worker, [ParentTest]}]

        assert :supervisor.count_children(parent) ==
                 [active: 1, specs: 1, supervisors: 0, workers: 1]
      end)

    assert_receive message
    assert Parent.handle_message(message) == :ignore

    assert_receive message
    assert Parent.handle_message(message) == :ignore

    Task.await(task)
  end

  property "started processes are registered" do
    check all child_specs <- child_specs(successful_child_spec()) do
      init()

      child_specs
      |> Enum.map(fn child_spec ->
        {:ok, pid} = Parent.start_child(child_spec)
        %{id: id(child_spec), meta: meta(child_spec), pid: pid}
      end)
      |> Enum.each(fn data ->
        assert Parent.child?(data.id)
        assert Parent.child_id(data.pid) == {:ok, data.id}
        assert Parent.child_meta(data.id) == {:ok, data.meta}
      end)
    end
  end

  property "processes which fail to start are not registered" do
    check all child_specs <- child_specs(failed_child_spec()) do
      init()

      Enum.each(
        child_specs,
        fn spec ->
          {:error, :not_started} = Parent.start_child(spec)

          assert Parent.num_children() == 0
          refute Parent.child?(spec.id)
          assert Parent.child_pid(spec.id) == :error
        end
      )
    end
  end

  property "handling of exit messages" do
    check all exit_data <- exit_data() do
      init()
      Enum.each(exit_data.starts, &Parent.start_child/1)

      Enum.each(exit_data.stops, fn child_spec ->
        {:ok, pid} = Parent.child_pid(id(child_spec))
        Agent.stop(pid, :shutdown)

        assert_receive {:EXIT, ^pid, reason} = message
        assert {:EXIT, ^pid, id, meta, ^reason} = Parent.handle_message(message)
        assert id == id(child_spec)
        assert meta == meta(child_spec)

        assert Parent.child_pid(id(child_spec)) == :error
        assert Parent.child_id(pid) == :error
      end)
    end
  end

  property "handling of other messages" do
    check all message <- one_of([term(), constant({:EXIT, self(), :normal})]) do
      init()
      assert Parent.handle_message(message) == nil
    end
  end

  property "shutting down children" do
    check all exit_data <- exit_data(), max_runs: 5 do
      init()
      Enum.each(exit_data.starts, &Parent.start_child/1)

      Enum.each(exit_data.stops, fn child_spec ->
        {:ok, pid} = Parent.child_pid(id(child_spec))
        assert Parent.shutdown_child(id(child_spec)) == :ok

        refute Process.alive?(pid)
        refute_receive {:EXIT, ^pid, _reason}
        assert Parent.child_pid(id(child_spec)) == :error
        assert Parent.child_id(pid) == :error
      end)
    end
  end

  property "shutting down all children" do
    check all child_specs <- child_specs(successful_child_spec()) do
      init()

      children =
        Enum.map(child_specs, fn spec ->
          {:ok, child} = Parent.start_child(spec)
          Process.monitor(child)
          child
        end)

      assert Parent.num_children() > 0
      Parent.shutdown_all(:shutdown)
      assert Parent.num_children() == 0

      # Check that the processes terminated in the reverse order they started in
      terminated_pids =
        Stream.repeatedly(fn ->
          assert_received {:DOWN, _ref, :process, pid, _reason}
          pid
        end)
        |> Enum.take(Enum.count(child_specs))

      assert terminated_pids == Enum.reverse(children)
    end
  end

  property "updating child meta" do
    check all picks <- picks() do
      init()
      Enum.each(picks.all, &({:ok, _} = Parent.start_child(&1)))

      meta_updater = &{:updated, &1}
      Enum.each(picks.some, &(:ok = Parent.update_child_meta(id(&1), meta_updater)))

      Enum.each(picks.some, &assert(Parent.child_meta(id(&1)) == {:ok, {:updated, meta(&1)}}))
    end
  end

  defp init() do
    unless Parent.initialized?(), do: Parent.initialize()
    Parent.shutdown_all(:kill)
  end
end
