defmodule Parent.Supervisor do
  use Parent.GenServer

  @spec start_link([Parent.start_spec()], Parent.GenServer.options()) :: GenServer.on_start()
  def start_link(children, options \\ []),
    do: Parent.GenServer.start_link(__MODULE__, children, options)

  @impl GenServer
  def init(children) do
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @spec child_spec({[Parent.start_spec()], Parent.GenServer.options()}) :: Supervisor.child_spec()
  def child_spec({children, options} = args) do
    args
    |> super()
    |> Map.put(:start, {__MODULE__, :start_link, [children, options]})
    |> Map.put(:id, Keyword.get(options, :name))
  end
end
