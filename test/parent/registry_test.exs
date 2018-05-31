defmodule Parent.RegistryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parent.Registry

  property "registered entries size" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)
      assert Registry.size(registry) == length(registrations)
    end
  end

  property "registered entries are properly mapped" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)
      Enum.each(registrations, &assert(Registry.id(registry, &1.pid) == {:ok, &1.id}))
      Enum.each(registrations, &assert(Registry.data(registry, &1.pid) == {:ok, &1.data}))
      Enum.each(registrations, &assert(Registry.pid(registry, &1.id) == {:ok, &1.pid}))
    end
  end

  property "registered entries can be iterated" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      assert Enum.sort(Registry.entries(registry)) ==
               Enum.sort(Enum.map(registrations, &{&1.pid, %{id: &1.id, data: &1.data}}))
    end
  end

  property "duplicate ids are not allowed" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      Enum.each(
        registrations,
        &assert_raise(RuntimeError, fn ->
          Registry.register(registry, &1.id, make_ref(), &1.data)
        end)
      )
    end
  end

  property "duplicate pids are not allowed" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      Enum.each(
        registrations,
        &assert_raise(RuntimeError, fn ->
          Registry.register(registry, make_ref(), &1.pid, &1.id)
        end)
      )
    end
  end

  property "pop" do
    check all unregs <- picks() do
      reducer = fn child, registry ->
        assert {:ok, id, data, registry} = Registry.pop(registry, child.pid)
        assert id == child.id
        assert data == child.data
        registry
      end

      registry = Enum.reduce(unregs.picks, register_all(unregs.registrations), reducer)

      survived_data = unregs.registrations -- unregs.picks

      assert Registry.size(registry) == length(survived_data)

      Enum.each(unregs.picks, &assert(Registry.id(registry, &1.pid) == :error))
      Enum.each(unregs.picks, &assert(Registry.data(registry, &1.pid) == :error))
      Enum.each(unregs.picks, &assert(Registry.pid(registry, &1.id) == :error))

      Enum.each(survived_data, &assert(Registry.id(registry, &1.pid) != :error))
      Enum.each(survived_data, &assert(Registry.data(registry, &1.pid) != :error))
      Enum.each(survived_data, &assert(Registry.pid(registry, &1.id) != :error))
    end
  end

  property "update" do
    check all updates <- picks() do
      update! = fn child, registry ->
        assert {:ok, registry} = Registry.update(registry, child.pid, &{:updated, &1})
        registry
      end

      registry = Enum.reduce(updates.picks, register_all(updates.registrations), update!)

      Enum.each(
        updates.picks,
        &assert(Registry.data(registry, &1.pid) == {:ok, {:updated, &1.data}})
      )
    end
  end

  defp unique_registrations() do
    bind(nonempty(list_of({small_term(), integer(), small_term()})), fn registrations ->
      registrations
      |> Stream.uniq_by(fn {id, _pid, _data} -> id end)
      |> Stream.uniq_by(fn {_id, pid, _data} -> pid end)
      |> Enum.map(fn {id, pid, data} -> %{id: id, pid: pid, data: data} end)
      |> constant()
    end)
  end

  defp small_term(), do: StreamData.scale(term(), fn _size -> 2 end)

  defp register_all(registrations) do
    Enum.reduce(registrations, Registry.new(), &Registry.register(&2, &1.id, &1.pid, &1.data))
  end

  defp picks() do
    bind(
      unique_registrations(),
      &fixed_map(%{
        registrations: constant(&1),
        picks: bind(nonempty(list_of(member_of(&1))), fn picks -> constant(Enum.uniq(picks)) end)
      })
    )
  end
end
