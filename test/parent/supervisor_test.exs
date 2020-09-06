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
        name: :my_supervisor,
        children: [
          child_spec(id: :child1),
          child_spec(id: :child2, start: fn -> :ignore end),
          Parent.child_spec(
            {Registry, name: :registry, keys: :unique},
            id: :child3
          )
        ]
      )

      assert [
               {:child1, _pid1, :worker, [Agent]},
               {:child3, _pid2, :supervisor, [Registry]}
             ] = :supervisor.which_children(:my_supervisor)
    end

    test "fails to start if a child fails to start" do
      Process.flag(:trap_exit, true)
      children = [child_spec(id: :child1, start: fn -> {:error, :some_reason} end)]

      assert capture_log(fn ->
               assert Supervisor.start_link(children: children) == {:error, :start_error}
             end) =~ "[error] Error starting the child :child1: :some_reason"
    end
  end

  defp start_supervisor!(opts) do
    pid = start_supervised!({Supervisor, opts})
    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)
    pid
  end

  defp child_spec(overrides),
    do: Parent.child_spec(%{start: {Agent, :start_link, [fn -> :ok end]}}, overrides)
end
