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
      Enum.each(registrations, &assert(Registry.name(registry, &1.pid) == {:ok, &1.name}))
      Enum.each(registrations, &assert(Registry.pid(registry, &1.name) == {:ok, &1.pid}))
    end
  end

  property "registered entries can be iterated" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      assert Enum.sort(Registry.entries(registry)) ==
               Enum.sort(Enum.map(registrations, &{&1.name, &1.pid}))
    end
  end

  property "duplicate names are not allowed" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      Enum.each(
        registrations,
        &assert_raise(RuntimeError, fn -> Registry.register(registry, &1.name, make_ref()) end)
      )
    end
  end

  property "duplicate pids are not allowed" do
    check all registrations <- unique_registrations() do
      registry = register_all(registrations)

      Enum.each(
        registrations,
        &assert_raise(RuntimeError, fn -> Registry.register(registry, make_ref(), &1.pid) end)
      )
    end
  end

  property "pop" do
    check all unregs <- unregs() do
      reducer = fn child, registry ->
        assert {:ok, name, registry} = Registry.pop(registry, child.pid)
        assert name == child.name
        registry
      end

      registry = Enum.reduce(unregs.deregistrations, register_all(unregs.registrations), reducer)

      survived_data = unregs.registrations -- unregs.deregistrations

      assert Registry.size(registry) == length(survived_data)

      Enum.each(unregs.deregistrations, &assert(Registry.name(registry, &1.pid) == :error))
      Enum.each(unregs.deregistrations, &assert(Registry.pid(registry, &1.name) == :error))

      Enum.each(survived_data, &assert(Registry.name(registry, &1.pid) != :error))
      Enum.each(survived_data, &assert(Registry.pid(registry, &1.name) != :error))
    end
  end

  defp unique_registrations() do
    bind(
      nonempty(list_of({StreamData.scale(term(), fn _size -> 2 end), integer()})),
      fn registrations ->
        registrations
        |> Stream.uniq_by(fn {name, _pid} -> name end)
        |> Stream.uniq_by(fn {_name, pid} -> pid end)
        |> Enum.map(fn {name, pid} -> %{name: name, pid: pid} end)
        |> constant()
      end
    )
  end

  defp register_all(registrations) do
    Enum.reduce(registrations, Registry.new(), &Registry.register(&2, &1.name, &1.pid))
  end

  defp unregs() do
    bind(
      unique_registrations(),
      &fixed_map(%{
        registrations: constant(&1),
        deregistrations:
          bind(nonempty(list_of(member_of(&1))), fn deregistrations ->
            constant(Enum.uniq(deregistrations))
          end)
      })
    )
  end
end
