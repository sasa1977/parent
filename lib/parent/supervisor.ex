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

  @spec shutdown_child(GenServer.server(), Parent.child_spec()) ::
          {:ok, Parent.on_shutdown_child()} | {:error, :unknown_child}
  def shutdown_child(supervisor, child_id),
    do: GenServer.call(supervisor, {:shutdown_child, child_id})

  @spec shutdown_all(GenServer.server()) :: :ok
  def shutdown_all(supervisor),
    do: GenServer.call(supervisor, :shutdown_all)

  @spec return_children(GenServer.server(), Parent.return_info()) :: :ok
  def return_children(supervisor, return_info),
    do: GenServer.call(supervisor, {:return_children, return_info})

  @impl GenServer
  def init(children) do
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:start_child, child_spec}, _call, state),
    do: {:reply, Parent.start_child(child_spec), state}

  def handle_call({:shutdown_child, child_id}, _call, state) do
    response =
      if Parent.child?(child_id),
        do: {:ok, Parent.shutdown_child(child_id)},
        else: {:error, :unknown_child}

    {:reply, response, state}
  end

  def handle_call(:shutdown_all, _call, state),
    do: {:reply, Parent.shutdown_all(), state}

  def handle_call({:return_children, return_info}, _call, state),
    do: {:reply, Parent.return_children(return_info), state}

  @spec child_spec([option]) :: Parent.child_spec()
end
