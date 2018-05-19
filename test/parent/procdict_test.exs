defmodule Parent.ProcdictTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Procdict
  import Parent.ChildSpecGenerators

  property "started processes are registered" do
    check all child_specs <- child_specs(successful_child_spec()) do
      fn ->
        Procdict.initialize()

        child_specs
        |> Enum.map(fn child_spec ->
          assert {:ok, pid} = Procdict.start_child(child_spec)
          %{id: id(child_spec), pid: pid}
        end)
        |> Enum.each(&assert(Procdict.name(&1.pid) == {:ok, &1.id}))
      end
      |> Task.async()
      |> Task.await()
    end
  end

  property "handling of exit messages" do
    check all exit_data <- exit_data() do
      fn ->
        Procdict.initialize()
        Enum.each(exit_data.starts, &Procdict.start_child/1)

        Enum.each(exit_data.stops, fn child_spec ->
          {:ok, pid} = Procdict.pid(id(child_spec))
          Agent.stop(pid, :shutdown)

          assert_receive {:EXIT, ^pid, reason} = message
          assert {:EXIT, ^pid, name, ^reason} = Procdict.handle_message(message)
          assert name == id(child_spec)

          assert Procdict.pid(id(child_spec)) == :error
          assert Procdict.name(pid) == :error
        end)
      end
      |> Task.async()
      |> Task.await()
    end
  end

  property "shutting down children" do
    check all exit_data <- exit_data(), max_runs: 5 do
      fn ->
        Procdict.initialize()
        Enum.each(exit_data.starts, &Procdict.start_child/1)

        Enum.each(exit_data.stops, fn child_spec ->
          {:ok, pid} = Procdict.pid(id(child_spec))
          assert Procdict.shutdown_child(id(child_spec)) == :ok

          refute Process.alive?(pid)
          refute_receive {:EXIT, ^pid, _reason}
          assert Procdict.pid(id(child_spec)) == :error
          assert Procdict.name(pid) == :error
        end)
      end
      |> Task.async()
      |> Task.await()
    end
  end

  property "shutting down all children" do
    check all child_specs <- child_specs(successful_child_spec()) do
      fn ->
        Procdict.initialize()
        Enum.each(child_specs, &({:ok, _} = Procdict.start_child(&1)))
        assert Procdict.size() > 0
        Procdict.shutdown_all(:shutdown)
        assert Procdict.size() == 0
      end
      |> Task.async()
      |> Task.await()
    end
  end
end
