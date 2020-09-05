defmodule Parent.SupervisorTest do
  use ExUnit.Case, async: true
  alias Parent.Supervisor

  setup do
    Mox.stub(Parent.RestartCounter.TimeProvider.Test, :now_ms, fn ->
      :erlang.unique_integer([:monotonic, :positive]) * :timer.seconds(5)
    end)

    :ok
  end

  test "starts the given children" do
    start_supervised!({
      Supervisor,
      name: :my_supervisor,
      children: [
        child_spec(id: :child1),
        child_spec(id: :child2, start: fn -> :ignore end),
        Parent.child_spec(
          {Registry, name: :registry, keys: :unique},
          id: :child3
        )
      ]
    })

    assert [
             {:child1, _pid1, :worker, [Agent]},
             {:child3, _pid2, :supervisor, [Registry]}
           ] = :supervisor.which_children(:my_supervisor)
  end

  test "fails to start if a child fails to start" do
    Process.flag(:trap_exit, true)
    children = [child_spec(id: :child1, start: fn -> {:error, :some_reason} end)]

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Supervisor.start_link(children: children) == {:error, :start_error}
           end) =~ "[error] Error starting the child :child1: :some_reason"
  end

  test "restarts the child automatically" do
    pid =
      start_supervised!({
        Supervisor,
        name: :my_supervisor, children: [child_spec(id: :child1, register?: true)]
      })

    Mox.allow(Parent.RestartCounter.TimeProvider.Test, self(), pid)

    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({Parent, :return_children, 2}, [], [:local])

    pid1 = Parent.whereis_child(:my_supervisor, :child1)
    Agent.stop(pid1)

    assert_receive {:trace, ^pid, :call, {Parent, :return_children, _args}}

    refute Parent.whereis_child(:my_supervisor, :child1) == pid1
  end

  defp child_spec(overrides) do
    Map.merge(
      %{id: make_ref(), start: {Agent, :start_link, [fn -> :ok end]}},
      Map.new(overrides)
    )
  end
end
