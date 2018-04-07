defmodule Parent.Procdict do
  alias Parent.{Functional, Registry}

  def initialize() do
    if Process.get(__MODULE__) != nil, do: raise("#{__MODULE__} is already initialized")
    Process.put(__MODULE__, Functional.initialize())
  end

  def start_child(child_spec) do
    with result <- Functional.start_child(state(), child_spec),
         {:ok, pid, state} <- result do
      store(state)
      {:ok, pid}
    end
  end

  def shutdown_child(child_id, shutdown \\ :timer.seconds(5)) do
    state = Functional.shutdown_child(state(), child_id, shutdown)
    store(state)
    :ok
  end

  def shutdown_all(reason, shutdown \\ :timer.seconds(5)) do
    state = Functional.shutdown_all(state(), reason, shutdown)
    store(state)
    :ok
  end

  def handle_message(message) do
    with {result, state} <- Functional.handle_message(state(), message) do
      store(state)
      result
    end
  end

  def entries(), do: Registry.entries(state())

  def size(), do: Registry.size(state())

  def name(pid), do: Registry.name(state(), pid)

  def pid(name), do: Registry.pid(state(), name)

  def state() do
    state = Process.get(__MODULE__)
    if is_nil(state), do: raise("#{__MODULE__} is not initialized")
    state
  end

  defp store(state), do: Process.put(__MODULE__, state)
end
