defmodule Parent.TestServer do
  use Parent.GenServer

  def start_link(initializer), do: Parent.GenServer.start_link(__MODULE__, initializer)

  def call(pid, fun), do: GenServer.call(pid, fun)

  def cast(pid, fun), do: GenServer.cast(pid, fun)

  def send(pid, fun), do: Kernel.send(pid, fun)

  def terminated_jobs(), do: Process.get(:terminated_jobs)

  @impl GenServer
  def init(initializer) do
    Process.put(:terminated_jobs, [])
    {:ok, initializer.()}
  end

  @impl GenServer
  def handle_call(fun, _from, state) do
    {response, state} = fun.(state)
    {:reply, response, state}
  end

  @impl GenServer
  def handle_cast(fun, state), do: {:noreply, fun.(state)}

  @impl GenServer
  def handle_info(fun, state), do: {:noreply, fun.(state)}

  @impl Parent.GenServer
  def handle_child_terminated(name, meta, pid, reason, state) do
    termination_info = %{name: name, meta: meta, pid: pid, reason: reason}
    Process.put(:terminated_jobs, [termination_info | Process.get(:terminated_jobs)])
    {:noreply, state}
  end
end
