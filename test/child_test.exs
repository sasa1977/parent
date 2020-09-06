defmodule ChildTest do
  use ExUnit.Case, async: true
  alias Parent.Supervisor

  describe "pid/2" do
    test "finds registered children by id" do
      parent = start_supervisor!(children: [child_spec(id: :child1), child_spec(id: :child2)])
      children_pids = children_pids(parent)

      assert Child.pid(parent, :child1) == children_pids.child1
      assert Child.pid(parent, :child2) == children_pids.child2

      assert GenServer.whereis({:via, Child, {parent, :child1}}) == children_pids.child1
      assert GenServer.whereis({:via, Child, {parent, :child2}}) == children_pids.child2
    end

    test "finds the child inside its parent" do
      parent1 = start_supervisor!(children: [child_spec(id: :child)])
      parent2 = start_supervisor!(children: [child_spec(id: :child)])

      children_pids1 = children_pids(parent1)
      children_pids2 = children_pids(parent2)

      assert Child.pid(parent1, :child) == children_pids1.child
      assert Child.pid(parent2, :child) == children_pids2.child
    end

    test "can dereference aliases" do
      registered_name = :"alias_#{System.unique_integer([:positive, :monotonic])}"
      parent = start_supervisor!(children: [child_spec(id: :child)], name: registered_name)
      :global.register_name(registered_name, parent)
      children_pids = children_pids(parent)

      assert Child.pid(registered_name, :child) == children_pids.child
      assert Child.pid({:global, registered_name}, :child) == children_pids.child
      assert Child.pid({:via, :global, registered_name}, :child) == children_pids.child
    end

    test "removes terminated child" do
      parent = start_supervisor!(children: [child_spec(id: :child)])
      Supervisor.shutdown_child(parent, :child)

      assert is_nil(Child.pid(parent, :child))
      assert :ets.tab2list(Parent.MetaRegistry.table!(parent)) == []
    end
  end

  describe "pids/2" do
    test "finds registered children by roles" do
      parent =
        start_supervisor!(
          children: [
            child_spec(id: :child1, roles: [:foo, :bar]),
            child_spec(id: :child2, roles: [:foo])
          ]
        )

      children_pids = children_pids(parent)

      assert Child.pids(parent, :foo) == [children_pids.child1, children_pids.child2]
      assert Child.pids(parent, :bar) == [children_pids.child1]
    end
  end

  defp start_supervisor!(opts) do
    opts = Keyword.merge([registry?: true], opts)
    pid = start_supervised!(Elixir.Supervisor.child_spec({Supervisor, opts}, id: make_ref()))
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp children_pids(parent) do
    parent
    |> :supervisor.which_children()
    |> Stream.map(fn {child_id, pid, _, _} -> {child_id, pid} end)
    |> Map.new()
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)
end
