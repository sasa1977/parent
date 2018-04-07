defmodule Parent.FunctionalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Functional
  import Parent.ChildSpecGenerators

  property "started processes are registered" do
    check all child_specs <- child_specs(successful_child_spec()) do
      initial_data = %{state: Functional.initialize(), children: []}

      reducer = fn child_spec, data ->
        assert {:ok, pid, state} = Functional.start_child(data.state, child_spec)
        %{data | state: state, children: [%{spec: child_spec, pid: pid} | data.children]}
      end

      data = Enum.reduce(child_specs, initial_data, reducer)

      for child <- data.children do
        assert Functional.name(data.state, child.pid) == {:ok, id(child.spec)}
        assert {:ok, child_spec} = Functional.child_spec(data.state, id(child.spec))
        assert child_spec.id == id(child_spec)
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

        assert {{:EXIT, ^pid, name, ^reason}, new_state} =
                 Functional.handle_message(state, message)

        assert name == id(child_spec)

        assert Functional.size(new_state) == Functional.size(state) - 1
        assert Functional.pid(new_state, id(child_spec)) == :error
        assert Functional.name(new_state, pid) == :error
        assert Functional.child_spec(new_state, id(child_spec)) == :error

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
        refute_receive {:EXIT, ^pid, _reason}

        assert Functional.size(new_state) == Functional.size(state) - 1
        assert Functional.pid(new_state, id(child_spec)) == :error
        assert Functional.name(new_state, pid) == :error
        assert Functional.child_spec(new_state, id(child_spec)) == :error

        new_state
      end)
    end
  end

  property "shutting down all children" do
    check all child_specs <- child_specs(successful_child_spec()) do
      initial_data = %{state: Functional.initialize(), children: []}

      reducer = fn child_spec, data ->
        assert {:ok, pid, state} = Functional.start_child(data.state, child_spec)
        %{data | state: state, children: [%{id: id(child_spec), pid: pid} | data.children]}
      end

      data = Enum.reduce(child_specs, initial_data, reducer)

      new_state = Functional.shutdown_all(data.state, :shutdown)

      assert Functional.size(new_state) == 0
      Enum.each(data.children, &assert(Process.alive?(&1.pid) == false))
      Enum.each(data.children, &assert(Functional.child_spec(new_state, &1.id) == :error))
    end
  end
end
