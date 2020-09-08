defmodule Parent.ClientTest do
  use ExUnit.Case, async: true
  import Parent.CaptureLog
  alias Parent.Client

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ok
  end

  describe "child_pid/1" do
    for registry? <- [true, false] do
      test "returns the pid of the given child when registry is #{registry?}" do
        parent =
          start_parent!(
            [child_spec(id: :child1), child_spec(id: :child2)],
            registry?: unquote(registry?)
          )

        assert {:ok, pid1} = Client.child_pid(parent, :child1)
        assert {:ok, pid2} = Client.child_pid(parent, :child2)

        assert [{:child1, ^pid1, _, _}, {:child2, ^pid2, _, _}] =
                 :supervisor.which_children(parent)
      end

      test "can dereference aliases when registry is #{registry?}" do
        registered_name = :"alias_#{System.unique_integer([:positive, :monotonic])}"
        parent = start_parent!([child_spec(id: :child)], name: registered_name)
        :global.register_name(registered_name, parent)

        assert {:ok, _} = Client.child_pid(registered_name, :child)
        assert {:ok, _} = Client.child_pid({:global, registered_name}, :child)
        assert {:ok, _} = Client.child_pid({:via, :global, registered_name}, :child)
      end

      test "returns error when child is unknown when registry is #{registry?}" do
        parent = start_parent!([], registry?: unquote(registry?))
        assert Client.child_pid(parent, :child) == :error
      end

      test "returns error if child is stopped when registry is #{registry?}" do
        parent =
          start_parent!(
            [child_spec(id: :child1), child_spec(id: :child2)],
            registry?: unquote(registry?)
          )

        Client.shutdown_child(parent, :child1)

        assert Client.child_pid(parent, :child1) == :error
        refute Client.child_pid(parent, :child2) == :error
      end
    end
  end

  describe "children/1" do
    for registry? <- [true, false] do
      test "returns children when registry is #{registry?}" do
        parent =
          start_parent!(
            [child_spec(id: :child1, meta: :meta1), child_spec(id: :child2, meta: :meta2)],
            registry?: unquote(registry?)
          )

        {:ok, child1} = Client.child_pid(parent, :child1)
        {:ok, child2} = Client.child_pid(parent, :child2)

        assert Enum.sort_by(Client.children(parent), &"#{&1.id}") == [
                 %{id: :child1, meta: :meta1, pid: child1},
                 %{id: :child2, meta: :meta2, pid: child2}
               ]
      end
    end
  end

  describe "via tuple" do
    for registry? <- [true, false] do
      test "resolves the pid of the given child when registry is #{registry?}" do
        parent =
          start_parent!(
            [child_spec(id: :child1), child_spec(id: :child2)],
            registry?: unquote(registry?)
          )

        assert pid1 = GenServer.whereis({:via, Client, {parent, :child1}})
        assert pid2 = GenServer.whereis({:via, Client, {parent, :child2}})

        assert [{:child1, ^pid1, _, _}, {:child2, ^pid2, _, _}] =
                 :supervisor.which_children(parent)
      end

      test "returns nil when child is unknown when registry is #{registry?}" do
        parent = start_parent!([], registry?: unquote(registry?))
        assert GenServer.whereis({:via, Client, {parent, :child}}) == nil
      end
    end
  end

  describe "child_meta/1" do
    for registry? <- [true, false] do
      test "returns the meta of the given child when registry is #{registry?}" do
        parent =
          start_parent!(
            [child_spec(id: :child1, meta: :meta1), child_spec(id: :child2, meta: :meta2)],
            registry?: unquote(registry?)
          )

        assert Client.child_meta(parent, :child1) == {:ok, :meta1}
        assert Client.child_meta(parent, :child2) == {:ok, :meta2}
      end

      test "returns error when child is unknown when registry is #{registry?}" do
        parent = start_parent!()
        assert Client.child_meta(parent, :child) == :error
      end
    end
  end

  describe "update_child_meta/1" do
    test "succeeds if child exists" do
      parent = start_parent!([child_spec(id: :child, meta: 1)])
      assert Client.update_child_meta(parent, :child, &(&1 + 1))
      assert Client.child_meta(parent, :child) == {:ok, 2}
    end

    test "returns error when child is unknown" do
      parent = start_parent!()
      assert Client.update_child_meta(parent, :child, & &1) == :error
    end
  end

  describe "start_child/1" do
    test "adds the additional child" do
      parent = start_parent!([child_spec(id: :child1)])
      assert {:ok, child2} = Client.start_child(parent, child_spec(id: :child2))
      assert child_pid!(parent, :child2) == child2
    end

    test "returns error" do
      parent = start_parent!([child_spec(id: :child1)])
      {:ok, child2} = Client.start_child(parent, child_spec(id: :child2))

      assert Client.start_child(parent, child_spec(id: :child2)) ==
               {:error, {:already_started, child2}}

      assert child_ids(parent) == [:child1, :child2]
      assert child_pid!(parent, :child2) == child2
    end

    test "handles child start crash" do
      parent = start_parent!([child_spec(id: :child1)])

      capture_log(fn ->
        spec =
          child_spec(id: :child2, start: {Agent, :start_link, [fn -> raise "some error" end]})

        assert {:error, {error, _stacktrace}} = Client.start_child(parent, spec)
        Process.sleep(100)
      end)

      assert child_ids(parent) == [:child1]
    end

    test "handles :ignore" do
      parent = start_parent!([child_spec(id: :child1)])

      assert Client.start_child(
               parent,
               child_spec(id: :child2, start: fn -> :ignore end)
             ) == {:ok, :undefined}

      assert child_ids(parent) == [:child1]
    end
  end

  describe "shutdown_child/1" do
    test "stops the given child" do
      parent = start_parent!([child_spec(id: :child)])
      assert {:ok, _info} = Client.shutdown_child(parent, :child)
      assert Client.child_pid(parent, :child) == :error
      assert child_ids(parent) == []
    end

    test "returns error when child is unknown" do
      parent = start_parent!()
      assert Client.shutdown_child(parent, :child) == {:error, :unknown_child}
    end
  end

  describe "restart_child/1" do
    test "stops the given child" do
      parent = start_parent!([child_spec(id: :child)])
      pid1 = child_pid!(parent, :child)
      assert Client.restart_child(parent, :child) == {[:child], nil}
      assert child_ids(parent) == [:child]
      refute child_pid!(parent, :child) == pid1
    end

    test "returns error when child is unknown" do
      pid = start_parent!()
      assert Client.restart_child(pid, :child) == {:error, :unknown_child}
    end
  end

  describe "shutdown_all/1" do
    test "stops all children" do
      parent = start_parent!([child_spec(id: :child1), child_spec(id: :child2)])
      assert Parent.children_to_return(Client.shutdown_all(parent)) == ~w/child1 child2/a
      assert child_ids(parent) == []
    end
  end

  describe "return_children/1" do
    test "returns all given children" do
      parent =
        start_parent!([
          child_spec(id: :child1, shutdown_group: :group1),
          child_spec(id: :child2, binds_to: [:child1], shutdown_group: :group2),
          child_spec(id: :child3, binds_to: [:child2]),
          child_spec(id: :child4, shutdown_group: :group1),
          child_spec(id: :child5, shutdown_group: :group2),
          child_spec(id: :child6)
        ])

      {:ok, %{return_info: return_info}} = Client.shutdown_child(parent, :child4)
      assert child_ids(parent) == [:child6]

      assert Client.return_children(parent, return_info) ==
               {~w/child1 child2 child3 child4 child5/a, nil}

      assert child_ids(parent) == ~w/child1 child2 child3 child4 child5 child6/a
    end
  end

  defp start_parent!(children \\ [], opts \\ []) do
    parent = start_supervised!({Parent.Supervisor, {children, opts}})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), parent)
    parent
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)

  defp child_pid!(parent, child_id) do
    {:ok, pid} = Client.child_pid(parent, child_id)
    pid
  end

  defp child_ids(parent), do: Enum.map(Client.children(parent), & &1.id)
end
