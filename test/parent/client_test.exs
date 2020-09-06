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
    test "returns the pid of the given child" do
      server = start_server!(children: [child_spec(id: :child1), child_spec(id: :child2)])
      assert {:ok, pid1} = Client.child_pid(server, :child1)
      assert {:ok, pid2} = Client.child_pid(server, :child1)
      assert [{:child1, pid1, _, _}, {:child2, pid2, _, _}] = :supervisor.which_children(server)
    end

    test "returns error when child is unknown" do
      server = start_server!()
      assert Client.child_pid(server, :child) == :error
    end
  end

  describe "child_meta/1" do
    test "returns the meta of the given child" do
      server =
        start_server!(
          children: [
            child_spec(id: :child1, meta: :meta1),
            child_spec(id: :child2, meta: :meta2)
          ]
        )

      assert Client.child_meta(server, :child1) == {:ok, :meta1}
      assert Client.child_meta(server, :child2) == {:ok, :meta2}
    end

    test "returns error when child is unknown" do
      server = start_server!()
      assert Client.child_meta(server, :child) == :error
    end
  end

  describe "update_child_meta/1" do
    test "succeeds if child exists" do
      server = start_server!(children: [child_spec(id: :child, meta: 1)])
      assert Client.update_child_meta(server, :child, &(&1 + 1))
      assert Client.child_meta(server, :child) == {:ok, 2}
    end

    test "returns error when child is unknown" do
      server = start_server!()
      assert Client.update_child_meta(server, :child, & &1) == :error
    end
  end

  describe "start_child/1" do
    test "adds the additional child" do
      server = start_server!(children: [child_spec(id: :child1)])
      assert {:ok, child2} = Client.start_child(server, child_spec(id: :child2))
      assert child_pid!(server, :child2) == child2
    end

    test "returns error" do
      server = start_server!(children: [child_spec(id: :child1)])
      {:ok, child2} = Client.start_child(server, child_spec(id: :child2))

      assert Client.start_child(server, child_spec(id: :child2)) ==
               {:error, {:already_started, child2}}

      assert child_ids(server) == [:child1, :child2]
      assert child_pid!(server, :child2) == child2
    end

    test "handles child start crash" do
      server = start_server!(children: [child_spec(id: :child1)])

      capture_log(fn ->
        spec =
          child_spec(id: :child2, start: {Agent, :start_link, [fn -> raise "some error" end]})

        assert {:error, {error, _stacktrace}} = Client.start_child(server, spec)
        Process.sleep(100)
      end)

      assert child_ids(server) == [:child1]
    end

    test "handles :ignore" do
      server = start_server!(children: [child_spec(id: :child1)])

      assert Client.start_child(
               server,
               child_spec(id: :child2, start: fn -> :ignore end)
             ) == {:ok, :undefined}

      assert child_ids(server) == [:child1]
    end
  end

  describe "shutdown_child/1" do
    test "stops the given child" do
      server = start_server!(children: [child_spec(id: :child)])
      assert {:ok, _info} = Client.shutdown_child(server, :child)
      assert Client.child_pid(server, :child) == :error
      assert child_ids(server) == []
    end

    test "returns error when child is unknown" do
      server = start_server!()
      assert Client.shutdown_child(server, :child) == {:error, :unknown_child}
    end
  end

  describe "restart_child/1" do
    test "stops the given child" do
      server = start_server!(children: [child_spec(id: :child)])
      pid1 = child_pid!(server, :child)
      assert Client.restart_child(server, :child) == :ok
      assert child_ids(server) == [:child]
      refute child_pid!(server, :child) == pid1
    end

    test "returns error when child is unknown" do
      pid = start_server!()
      assert Client.restart_child(pid, :child) == {:error, :unknown_child}
    end
  end

  describe "shutdown_all/1" do
    test "stops all children" do
      server = start_server!(children: [child_spec(id: :child1), child_spec(id: :child2)])
      assert Client.shutdown_all(server) == :ok
      assert child_ids(server) == []
    end
  end

  describe "return_children/1" do
    test "returns all given children" do
      server =
        start_server!(
          children: [
            child_spec(id: :child1, shutdown_group: :group1),
            child_spec(id: :child2, binds_to: [:child1], shutdown_group: :group2),
            child_spec(id: :child3, binds_to: [:child2]),
            child_spec(id: :child4, shutdown_group: :group1),
            child_spec(id: :child5, shutdown_group: :group2),
            child_spec(id: :child6)
          ]
        )

      {:ok, %{return_info: return_info}} = Client.shutdown_child(server, :child4)
      assert child_ids(server) == [:child6]

      assert Client.return_children(server, return_info) == :ok
      assert child_ids(server) == ~w/child1 child2 child3 child4 child5 child6/a
    end
  end

  defp start_server!(opts \\ []) do
    server = start_supervised!({Parent.Supervisor, opts})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), server)
    server
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)

  defp child_pid!(server, child_id) do
    {:ok, pid} = Client.child_pid(server, child_id)
    pid
  end

  defp child_ids(server) do
    server
    |> :supervisor.which_children()
    |> Enum.map(fn {child_id, _, _, _} -> child_id end)
  end
end
