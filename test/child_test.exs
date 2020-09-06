defmodule ChildTest do
  use ExUnit.Case, async: true
  alias Parent.{Client, Supervisor}

  describe "pid/2" do
    test "finds registered children by id" do
      parent = start_supervisor!(children: [child_spec(id: :child1), child_spec(id: :child2)])

      assert Child.pid(parent, :child1) == child_pid!(parent, :child1)
      assert Child.pid(parent, :child2) == child_pid!(parent, :child2)

      assert GenServer.whereis({:via, Child, {parent, :child1}}) == child_pid!(parent, :child1)
      assert GenServer.whereis({:via, Child, {parent, :child2}}) == child_pid!(parent, :child2)
    end

    test "finds the child inside its parent" do
      parent1 = start_supervisor!(children: [child_spec(id: :child)])
      parent2 = start_supervisor!(children: [child_spec(id: :child)])

      assert Child.pid(parent1, :child) == child_pid!(parent1, :child)
      assert Child.pid(parent2, :child) == child_pid!(parent2, :child)
    end

    test "can dereference aliases" do
      registered_name = :"alias_#{System.unique_integer([:positive, :monotonic])}"
      parent = start_supervisor!(children: [child_spec(id: :child)], name: registered_name)
      :global.register_name(registered_name, parent)

      assert Child.pid(registered_name, :child) == child_pid!(parent, :child)
      assert Child.pid({:global, registered_name}, :child) == child_pid!(parent, :child)
      assert Child.pid({:via, :global, registered_name}, :child) == child_pid!(parent, :child)
    end

    test "removes terminated child" do
      parent = start_supervisor!(children: [child_spec(id: :child)])
      Client.shutdown_child(parent, :child)

      assert is_nil(Child.pid(parent, :child))
      assert :ets.tab2list(Parent.MetaRegistry.table!(parent)) == []
    end

    test "discovers the child after restart" do
      parent = start_supervisor!(children: [child_spec(id: :child)])
      Client.restart_child(parent, :child)
      assert Child.pid(parent, :child) == child_pid!(parent, :child)
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

      assert Child.pids(parent, :foo) == [
               child_pid!(parent, :child1),
               child_pid!(parent, :child2)
             ]

      assert Child.pids(parent, :bar) == [child_pid!(parent, :child1)]
    end
  end

  describe "sibling/1" do
    test "returns the pid of the sibling or nil if the sibling doesn't exist" do
      parent = start_supervisor!(children: [child_spec(id: :child1), child_spec(id: :child2)])

      assert Agent.get(child_pid!(parent, :child1), fn _ -> Child.sibling(:child2) end) ==
               child_pid!(parent, :child2)

      assert Agent.get(child_pid!(parent, :child2), fn _ -> Child.sibling(:child1) end) ==
               child_pid!(parent, :child1)

      assert Agent.get(child_pid!(parent, :child1), fn _ -> Child.sibling(:child3) end) == nil
    end

    test "raises if parent is not registry" do
      Task.async(fn ->
        assert_raise RuntimeError, "Parent is not a registry", fn -> Child.sibling(:sibling) end
      end)
      |> Task.await()
    end
  end

  defp start_supervisor!(opts) do
    opts = Keyword.merge([registry?: true], opts)
    pid = start_supervised!(Elixir.Supervisor.child_spec({Supervisor, opts}, id: make_ref()))
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp child_pid!(parent, child_id) do
    {:ok, pid} = Client.child_pid(parent, child_id)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)
end
