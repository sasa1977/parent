defmodule Parent.Supervisor do
  use Parent.GenServer

  @type option :: Parent.GenServer.option() | {:children, [Parent.start_spec()]}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(options) do
    {children, options} = Keyword.pop(options, :children, [])
    Parent.GenServer.start_link(__MODULE__, children, options)
  end

  @impl GenServer
  def init(children) do
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @spec child_spec([option]) :: Parent.child_spec()
end
