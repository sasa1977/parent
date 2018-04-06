defmodule Parent.ChildSpecGenerators do
  import StreamData

  def child_specs(child_spec) do
    child_spec
    |> list_of()
    |> nonempty()
    |> bind(fn specs -> specs |> Enum.uniq_by(&id/1) |> constant() end)
  end

  def id(%{id: id}), do: id
  def id({_mod, arg}), do: arg
  def id(mod) when is_atom(mod), do: nil

  def successful_child_spec() do
    bind(
      id(),
      &one_of([
        fixed_map(%{id: constant(&1), start: successful_start()}),
        constant({__MODULE__, &1}),
        constant(__MODULE__)
      ])
    )
  end

  def failed_child_spec() do
    bind(id(), &fixed_map(%{id: constant(&1), start: constant({__MODULE__, :test_start, []})}))
  end

  def exit_data() do
    bind(
      child_specs(successful_child_spec()),
      &fixed_map(%{
        starts: constant(&1),
        stops: bind(nonempty(list_of(member_of(&1))), fn stops -> constant(Enum.uniq(stops)) end)
      })
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
end
