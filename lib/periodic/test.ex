defmodule Periodic.Test do
  public_telemetry_events = ~w/started finished skipped killed_previous/a

  @telemetry_events if Mix.env() != :test,
                      do: public_telemetry_events,
                      else: [:next_tick | public_telemetry_events]

  def tick(pid), do: GenServer.call(pid, :tick)

  def observe(telemetry_id),
    do: Enum.each(@telemetry_events, &attach_telemetry_handler(telemetry_id, &1))

  defmacro assert_periodic_event(event, metadata \\ quote(do: _), measurements \\ quote(do: _)) do
    quote do
      assert_receive {
                       unquote(__MODULE__),
                       unquote(event),
                       unquote(metadata),
                       unquote(measurements)
                     },
                     100
    end
  end

  defmacro refute_periodic_event(event, metadata \\ quote(do: _), measurements \\ quote(do: _)) do
    quote do
      refute_receive {
                       unquote(__MODULE__),
                       unquote(event),
                       unquote(metadata),
                       unquote(measurements)
                     },
                     100
    end
  end

  defp attach_telemetry_handler(telemetry_id, event) do
    handler_id = make_ref()
    event_name = [Periodic, telemetry_id, event]
    :telemetry.attach(handler_id, event_name, telemetry_handler(event_name), nil)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp telemetry_handler(event_name) do
    test_pid = self()

    fn [Periodic, _id, event] = ^event_name, measurements, metadata, nil ->
      send(test_pid, {__MODULE__, event, metadata, measurements})
    end
  end
end
