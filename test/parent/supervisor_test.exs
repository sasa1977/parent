defmodule Parent.SupervisorTest do
  use ExUnit.Case, async: true
  import Parent.CaptureLog
  alias Parent.Supervisor

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the given children" do
      start_supervisor!(
        [
          child_spec(id: :child1),
          child_spec(id: :child2, start: fn -> :ignore end),
          child_spec(id: :child3)
        ],
        name: :my_supervisor
      )

      assert [%{id: :child1}, %{id: :child2}, %{id: :child3}] =
               Parent.Client.children(:my_supervisor)
    end

    test "fails to start if a child fails to start" do
      Process.flag(:trap_exit, true)
      children = [child_spec(id: :child1, start: fn -> {:error, :some_reason} end)]

      assert capture_log(fn ->
               assert Supervisor.start_link(children) == {:error, :start_error}
             end) =~ "[error] Error starting the child :child1: :some_reason"
    end
  end

  describe "__using__/1" do
    defmodule MySupervisor do
      use Supervisor
    end

    test "works when only module is passed" do
      spec = Elixir.Supervisor.child_spec(MySupervisor, [])
      assert spec.type == :supervisor
      assert spec.shutdown == :infinity
      assert spec.start == {MySupervisor, :start_link, [[]]}
    end

    test "passes arg to start_link" do
      spec = Elixir.Supervisor.child_spec({MySupervisor, :arg}, [])
      assert spec.start == {MySupervisor, :start_link, [:arg]}
    end
  end

  defp start_supervisor!(children, opts) do
    pid = start_supervised!({Supervisor, {children, opts}})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)
end
