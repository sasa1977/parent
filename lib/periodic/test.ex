defmodule Periodic.Test do
  @moduledoc """
  Helpers for testing a periodic job.

  See the "Testing" section in `Periodic` documentation for details.
  """

  public_telemetry_events = ~w/started finished skipped stopped_previous/a

  @telemetry_events if Mix.env() != :test,
                      do: public_telemetry_events,
                      else: [:next_tick | public_telemetry_events]

  @doc """
  Sends a tick signal to the given scheduler.

  This function returns after the tick signal has been sent, and the job has been started.
  However, the function doesn't wait for the job to finish. If you want complete synchronism, use
  `sync_tick/2`
  """
  @spec tick(GenServer.server()) :: :ok
  def tick(pid_or_name), do: :ok = GenServer.call(pid_or_name, {:tick, []})

  @doc """
  Sends a tick signal to the given scheduler and waits for the job to finish.

  The function returns the job exit reason, or error if the job hasn't been started.
  """
  @spec sync_tick(GenServer.server(), non_neg_integer | :infinity) ::
          {:ok, job_exit_reason :: any} | {:error, :job_not_started}
  def sync_tick(pid_or_name, timeout \\ :timer.seconds(5)) do
    GenServer.call(pid_or_name, {:tick, [await_job?: true]}, timeout)
  end

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
    :telemetry.attach(handler_id, event_name, &__MODULE__.telemetry_handler/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def telemetry_handler([Periodic, telemetry_id, event], measurements, metadata, test_pid),
    do: send(test_pid, {__MODULE__, telemetry_id, event, metadata, measurements})
end
