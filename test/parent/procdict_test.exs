defmodule Parent.ProcdictTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Procdict
  import Parent.ChildSpecGenerators

  test "awaits child termination" do
    init()

    child = %{id: :child, start: fn -> Task.start_link(fn -> :ok end) end, meta: :child_meta}
    {:ok, child_pid} = Procdict.start_child(child)

    assert {^child_pid, :child_meta, :normal} = Procdict.await_termination(:child, 1000)
    refute Process.alive?(child_pid)
    assert Procdict.size() == 0
  end

  test "timeouts awaiting child termination" do
    init()

    child = %{id: :child, start: fn -> Agent.start_link(fn -> :ok end) end, meta: :child_meta}
    {:ok, child_pid} = Procdict.start_child(child)

    assert Procdict.await_termination(:child, 100) == :timeout
    assert Process.alive?(child_pid)
    assert Procdict.size() == 1
    assert Procdict.entries() == [{:child, child_pid, :child_meta}]
  end

  property "started processes are registered" do
    check all child_specs <- child_specs(successful_child_spec()) do
      init()

      child_specs
      |> Enum.map(fn child_spec ->
        assert {:ok, pid} = Procdict.start_child(child_spec)
        %{id: id(child_spec), meta: meta(child_spec), pid: pid}
      end)
      |> Enum.each(fn data ->
        assert Procdict.id(data.pid) == {:ok, data.id}
        assert Procdict.meta(data.id) == {:ok, data.meta}
      end)
    end
  end

  property "handling of exit messages" do
    check all exit_data <- exit_data() do
      init()
      Enum.each(exit_data.starts, &Procdict.start_child/1)

      Enum.each(exit_data.stops, fn child_spec ->
        {:ok, pid} = Procdict.pid(id(child_spec))
        Agent.stop(pid, :shutdown)

        assert_receive {:EXIT, ^pid, reason} = message
        assert {:EXIT, ^pid, id, meta, ^reason} = Procdict.handle_message(message)
        assert id == id(child_spec)
        assert meta == meta(child_spec)

        assert Procdict.pid(id(child_spec)) == :error
        assert Procdict.id(pid) == :error
      end)
    end
  end

  property "shutting down children" do
    check all exit_data <- exit_data(), max_runs: 5 do
      init()
      Enum.each(exit_data.starts, &Procdict.start_child/1)

      Enum.each(exit_data.stops, fn child_spec ->
        {:ok, pid} = Procdict.pid(id(child_spec))
        assert Procdict.shutdown_child(id(child_spec)) == :ok

        refute Process.alive?(pid)
        refute_receive {:EXIT, ^pid, _reason}
        assert Procdict.pid(id(child_spec)) == :error
        assert Procdict.id(pid) == :error
      end)
    end
  end

  property "shutting down all children" do
    check all child_specs <- child_specs(successful_child_spec()) do
      init()
      Enum.each(child_specs, &({:ok, _} = Procdict.start_child(&1)))
      assert Procdict.size() > 0
      Procdict.shutdown_all(:shutdown)
      assert Procdict.size() == 0
    end
  end

  property "updating child meta" do
    check all picks <- picks() do
      init()
      Enum.each(picks.all, &({:ok, _} = Procdict.start_child(&1)))

      meta_updater = &{:updated, &1}
      Enum.each(picks.some, &(:ok = Procdict.update_meta(id(&1), meta_updater)))

      Enum.each(picks.some, &assert(Procdict.meta(id(&1)) == {:ok, {:updated, meta(&1)}}))
    end
  end

  defp init() do
    unless Procdict.initialized?(), do: Procdict.initialize()
    Procdict.shutdown_all(:kill)
  end
end
