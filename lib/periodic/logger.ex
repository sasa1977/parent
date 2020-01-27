defmodule Periodic.Logger do
  @moduledoc "Telemetry handler that support basic logging of periodic scheduler events."

  require Logger

  @doc "Installs telemetry handlers for the given scheduler."
  @spec install(any) :: :ok
  def install(telemetry_id) do
    Enum.each(
      ~w/started finished skipped stopped_previous/a,
      &attach_telemetry_handler(telemetry_id, &1)
    )
  end

  defp attach_telemetry_handler(telemetry_id, event) do
    handler_id = make_ref()
    event_name = [Periodic, telemetry_id, event]
    :telemetry.attach(handler_id, event_name, &telemetry_handler/4, nil)
  end

  defp telemetry_handler([Periodic, telemetry_id, event], measurements, meta, nil) do
    Logger.log(log_level(event, meta), message(telemetry_id, event, measurements, meta))
  end

  defp log_level(:started, _meta), do: :info
  defp log_level(:skipped, _meta), do: :info
  defp log_level(:stopped_previous, _meta), do: :warn

  defp log_level(:finished, meta),
    do: if(meta.reason in [:shutdown, :normal], do: :info, else: :error)

  defp message(telemetry_id, event, measurements, meta) do
    "Periodic(#{inspect(telemetry_id)}): #{message(event, meta, measurements)}"
  end

  defp message(:started, meta, _measurements), do: "job #{inspect(meta.job)} started"

  defp message(:finished, meta, measurements) do
    [
      "job #{inspect(meta.job)} ",
      case meta.reason do
        :normal -> "finished"
        :shutdown -> "shut down"
        :killed -> "killed"
        other -> "exited with reason #{inspect(other)}"
      end,
      ", duration=#{measurements.time}us"
    ]
  end

  defp message(:skipped, _meta, _measurements),
    do: "skipped starting the job because the previous instance is still running"

  defp message(:stopped_previous, _meta, _measurements),
    do: "killed previous job instance, because the new job is about to be started"
end
