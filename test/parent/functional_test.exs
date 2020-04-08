defmodule Parent.FunctionalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Functional
  import Parent.ChildSpecGenerators

  test "shutting down a child which refuses to stop" do
    state = Functional.initialize()

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

    {:ok, stubborn_pid, state} = Functional.start_child(state, stubborn_child)
    {:ok, normal_pid, state} = Functional.start_child(state, normal_child)

    state = Functional.shutdown_all(state, :shutdown)

    assert Functional.size(state) == 0
    refute Process.alive?(stubborn_pid)
    refute Process.alive?(normal_pid)
  end

  test "child timeout" do
    state = Functional.initialize()

    timeout_child = %{
      id: :timeout_child,
      start: fn -> Agent.start_link(fn -> :ok end) end,
      timeout: 10,
      meta: :timeout_meta
    }

    {:ok, timeout_pid, state} = Functional.start_child(state, timeout_child)

    assert_receive {Parent.Functional, _, _} = message
    assert {exit_response, state} = Functional.handle_message(state, message)
    assert exit_response == {:EXIT, timeout_pid, :timeout_child, :timeout_meta, :timeout}
    assert Functional.size(state) == 0
    refute Process.alive?(timeout_pid)
  end

  test "awaits child termination" do
    state = Functional.initialize()

    child = %{id: :child, start: fn -> Task.start_link(fn -> :ok end) end, meta: :child_meta}

    {:ok, child_pid, state} = Functional.start_child(state, child)

    assert {result, state} = Functional.await_termination(state, :child, 1000)
    refute Process.alive?(child_pid)
    assert result == {child_pid, :child_meta, :normal}
    assert Functional.size(state) == 0
  end

  test "timeouts awaiting child termination" do
    state = Functional.initialize()

    child = %{id: :child, start: fn -> Agent.start_link(fn -> :ok end) end, meta: :child_meta}

    {:ok, child_pid, state} = Functional.start_child(state, child)

    assert Functional.await_termination(state, :child, 100) == :timeout
    assert Process.alive?(child_pid)
    assert Functional.size(state) == 1
    assert Functional.entries(state) == [{:child, child_pid, :child_meta}]
  end

  property "started processes are registered" do
    check all child_specs <- child_specs(successful_child_spec()) do
      initial_data = %{state: Functional.initialize(), children: []}

      reducer = fn child_spec, data ->
        assert {:ok, pid, state} = Functional.start_child(data.state, child_spec)
        %{data | state: state, children: [%{spec: child_spec, pid: pid} | data.children]}
      end

      data = Enum.reduce(child_specs, initial_data, reducer)

      for child <- data.children do
        assert Functional.id(data.state, child.pid) == {:ok, id(child.spec)}
        assert {:ok, meta} = Functional.meta(data.state, id(child.spec))
        assert meta == meta(child.spec)
      end
    end
  end

  property "processes which fail to start are not registered" do
    check all child_specs <- child_specs(failed_child_spec()) do
      state = Functional.initialize()

      Enum.each(
        child_specs,
        &assert(Functional.start_child(state, &1) == {:error, :not_started})
      )
    end
  end

  property "handling of exit messages" do
    check all exit_data <- exit_data() do
      state =
        Enum.reduce(exit_data.starts, Functional.initialize(), fn child_spec, state ->
          {:ok, _pid, state} = Functional.start_child(state, child_spec)
          state
        end)

      Enum.reduce(exit_data.stops, state, fn child_spec, state ->
        {:ok, pid} = Functional.pid(state, id(child_spec))
        Agent.stop(pid, :shutdown)
        assert_receive {:EXIT, ^pid, reason} = message

        assert {{:EXIT, ^pid, id, meta, ^reason}, new_state} =
                 Functional.handle_message(state, message)

        assert id == id(child_spec)
        assert meta == meta(child_spec)

        assert Functional.size(new_state) == Functional.size(state) - 1
        assert Functional.pid(new_state, id(child_spec)) == :error
        assert Functional.id(new_state, pid) == :error
        assert Functional.meta(new_state, id(child_spec)) == :error

        new_state
      end)
    end
  end

  property "handling of other messages" do
    check all message <- one_of([term(), constant({:EXIT, self(), :normal})]) do
      state = Functional.initialize()
      assert Functional.handle_message(state, message) == :error
    end
  end

  property "shutting down children" do
    check all exit_data <- exit_data(), max_runs: 5 do
      state =
        Enum.reduce(exit_data.starts, Functional.initialize(), fn child_spec, state ->
          {:ok, _pid, state} = Functional.start_child(state, child_spec)
          state
        end)

      Enum.reduce(exit_data.stops, state, fn child_spec, state ->
        {:ok, pid} = Functional.pid(state, id(child_spec))
        new_state = Functional.shutdown_child(state, id(child_spec))
        refute Process.alive?(pid)
        refute_receive {:EXIT, ^pid, _reason}

        assert Functional.size(new_state) == Functional.size(state) - 1
        assert Functional.pid(new_state, id(child_spec)) == :error
        assert Functional.id(new_state, pid) == :error
        assert Functional.meta(new_state, id(child_spec)) == :error

        new_state
      end)
    end
  end

  property "shutting down all children" do
    check all child_specs <- child_specs(successful_child_spec()) do
      {children, state} =
        Enum.flat_map_reduce(
          child_specs,
          Functional.initialize(),
          fn child_spec, state ->
            assert {:ok, pid, state} = Functional.start_child(state, child_spec)
            Process.monitor(pid)
            {[%{id: id(child_spec), pid: pid}], state}
          end
        )

      new_state = Functional.shutdown_all(state, :shutdown)

      assert Functional.size(new_state) == 0
      Enum.each(children, &assert(Process.alive?(&1.pid) == false))
      Enum.each(children, &assert(Functional.meta(new_state, &1.id) == :error))

      # Check that the processes terminated in the reverse order they started in
      terminated_pids =
        Stream.repeatedly(fn ->
          assert_received {:DOWN, _ref, :process, pid, _reason}
          pid
        end)
        |> Enum.take(Enum.count(child_specs))

      assert terminated_pids == children |> Stream.map(& &1.pid) |> Enum.reverse()
    end
  end

  property "updating child meta" do
    check all picks <- picks() do
      state =
        Enum.reduce(picks.all, Functional.initialize(), fn child_spec, state ->
          {:ok, _pid, state} = Functional.start_child(state, child_spec)
          state
        end)

      Enum.reduce(picks.some, state, fn child_spec, state ->
        assert {:ok, new_state} = Functional.update_meta(state, id(child_spec), &{:updated, &1})
        assert Functional.meta(new_state, id(child_spec)) == {:ok, {:updated, meta(child_spec)}}
        new_state
      end)
    end
  end
end
