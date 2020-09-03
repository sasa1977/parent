defmodule TestChild do
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts || [])

  def start(overrides \\ [], child_opts \\ []) do
    %{
      id: :erlang.unique_integer([:positive, :monotonic]),
      start: {TestChild, :start_link, [child_opts]}
    }
    |> Map.merge(Map.new(overrides))
    |> Parent.start_child()
  end

  def start!(overrides \\ [], child_opts \\ []) do
    {:ok, pid} = start(overrides, child_opts)
    pid
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :trap_exit?), do: Process.flag(:trap_exit, true)
    Keyword.get(opts, :init, &{:ok, &1}).(opts)
  end

  @impl GenServer
  def terminate(_reason, opts) do
    if Keyword.get(opts, :block_terminate?), do: Process.sleep(:infinity)
  end
end
