defmodule Parent.ProcdictTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Procdict

  property "started processes are registered" do
    check all child_specs <- child_specs() do
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

          refute_receive {:EXIT, ^pid, _reason}
          assert Procdict.pid(id(child_spec)) == :error
          assert Procdict.name(pid) == :error
        end)
      end
      |> Task.async()
      |> Task.await()
    end
  end

  defp child_specs() do
    successful_child_spec()
    |> list_of()
    |> nonempty()
    |> bind(fn specs -> specs |> Enum.uniq_by(&id/1) |> constant() end)
  end

  defp id(%{id: id}), do: id
  defp id({_mod, arg}), do: arg
  defp id(mod) when is_atom(mod), do: nil

  defp successful_child_spec() do
    bind(
      id(),
      &one_of([
        fixed_map(%{id: constant(&1), start: successful_start()}),
        constant({__MODULE__, &1}),
        constant(__MODULE__)
      ])
    )
  end

  defp id(), do: StreamData.scale(term(), fn _size -> 2 end)

  @doc false
  def child_spec(arg), do: %{id: arg, start: fn -> Agent.start_link(fn -> :ok end) end}

  defp successful_start() do
    one_of([
      constant({Agent, :start_link, [fn -> :ok end]}),
      constant(fn -> Agent.start_link(fn -> :ok end) end)
    ])
  end

  @doc false
  def test_start(), do: {:error, :not_started}

  defp exit_data() do
    bind(
      child_specs(),
      &fixed_map(%{
        starts: constant(&1),
        stops: bind(nonempty(list_of(member_of(&1))), fn stops -> constant(Enum.uniq(stops)) end)
      })
    )
  end
end
