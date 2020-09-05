defmodule Parent.Supervisor do
  use Parent.GenServer

  @type option :: [Parent.GenServer.option() | {:children, [Parent.child_spec()]}]

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(options) do
    {children, options} = Keyword.pop!(options, :children)
    Parent.GenServer.start_link(__MODULE__, children, options)
  end

  @spec start_child(GenServer.server(), Parent.child_spec()) :: Supervisor.on_start_child()
  def start_child(supervisor, child_spec),
    do: GenServer.call(supervisor, {:start_child, child_spec}, :infinity)

  @impl GenServer
  def init(children) do
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:start_child, child_spec}, _call, state),
    do: {:reply, Parent.start_child(child_spec), state}

  @spec child_spec([option]) :: Parent.child_spec()
end
