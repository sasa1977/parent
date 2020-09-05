defmodule Parent.RestartCounter do
  @moduledoc false

  @opaque t ::
            %{
              max_restarts: pos_integer,
              interval: pos_integer,
              recorded: :queue.queue(pos_integer),
              size: non_neg_integer
            }
            | nil

  @time_provider if Mix.env() == :test,
                   do: __MODULE__.TimeProvider.Test,
                   else: __MODULE__.TimeProvider.Monotonic

  @spec new(:infinity | non_neg_integer, pos_integer) :: t
  def new(:infinity, _max_seconds), do: nil

  def new(max_restarts, max_seconds) do
    %{
      max_restarts: max_restarts,
      interval: :timer.seconds(max_seconds),
      recorded: :queue.new(),
      size: 0
    }
  end

  @spec record_restart(t) :: {:ok, t} | :error
  def record_restart(nil), do: {:ok, nil}

  def record_restart(state) do
    now = @time_provider.now_ms()

    state =
      state
      |> purge_old_records(now)
      |> Map.update!(:recorded, &:queue.in(now, &1))
      |> Map.update!(:size, &(&1 + 1))

    if state.size > state.max_restarts, do: :error, else: {:ok, state}
  end

  defp purge_old_records(%{interval: interval} = state, now) do
    state
    |> Stream.iterate(fn state ->
      case :queue.out(state.recorded) do
        {{:value, time}, recorded} when time + interval - 1 < now ->
          %{state | recorded: recorded, size: state.size - 1}

        _other ->
          nil
      end
    end)
    |> Stream.take_while(&(not is_nil(&1)))
    |> Enum.at(-1)
  end

  defmodule TimeProvider do
    @moduledoc false
    @callback now_ms :: integer
  end

  defmodule TimeProvider.Monotonic do
    @moduledoc false
    @behaviour TimeProvider

    @impl TimeProvider
    def now_ms, do: :erlang.monotonic_time(:millisecond)
  end

  if Mix.env() == :test do
    Mox.defmock(TimeProvider.Test, for: TimeProvider)
  end
end
