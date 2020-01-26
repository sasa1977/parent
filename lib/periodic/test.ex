defmodule Periodic.Test do
  @moduledoc """
  Helpers for testing a periodic job.

  See the "Testing" section in `Periodic` documentation for details.
  """

  public_telemetry_events = ~w/started finished skipped stopped_previous/a

  @telemetry_events if Mix.env() != :test,
                      do: public_telemetry_events,
                      else: [:next_tick | public_telemetry_events]

  @doc "Sends a tick signal to the given scheduler."
  @spec tick(GenServer.name()) :: :ok
  def tick(pid_or_name), do: GenServer.call(pid_or_name, :tick)

  @doc "Subscribes to telemetry events of the given scheduler."
  @spec observe(any) :: :ok
  def observe(telemetry_id),
    do: Enum.each(@telemetry_events, &attach_telemetry_handler(telemetry_id, &1))

  @doc "Waits for the given telemetry event."
  defmacro assert_periodic_event(
             telemetry_id,
             event,
             metadata \\ quote(do: _),
             measurements \\ quote(do: _)
           ) do
    quote do
      assert_receive {
                       unquote(__MODULE__),
                       unquote(telemetry_id),
                       unquote(event),
                       unquote(metadata),
                       unquote(measurements)
                     },
                     100
    end
  end

  @doc "Asserts that the given telemetry event won't be emitted."
  defmacro refute_periodic_event(
             telemetry_id,
             event,
             metadata \\ quote(do: _),
             measurements \\ quote(do: _)
           ) do
    quote do
      refute_receive {
                       unquote(__MODULE__),
                       unquote(telemetry_id),
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

    fn [Periodic, telemetry_id, event] = ^event_name, measurements, metadata, nil ->
      send(test_pid, {__MODULE__, telemetry_id, event, metadata, measurements})
    end
  end
end
