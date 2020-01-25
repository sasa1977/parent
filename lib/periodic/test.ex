defmodule Periodic.Test do
  def tick(pid), do: GenServer.call(pid, :tick)

  def observe() do
    handler_id = make_ref()
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [Periodic],
      fn [Periodic], measurements, metadata, nil ->
        send(test_pid, {Periodic.Test, metadata, measurements})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defmacro assert_periodic_event(event, measurements \\ quote(do: _)) do
    quote do
      assert_receive {Periodic.Test, unquote(event), unquote(measurements)}
    end
  end

  defmacro refute_periodic_event(event, measurements \\ quote(do: _)) do
    quote do
      refute_receive {Periodic.Test, unquote(event), unquote(measurements)}
    end
  end
end
