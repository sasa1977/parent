defmodule Parent.Procdict do
  alias Parent.Functional

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

  def shutdown_child(child_name) do
    state = Functional.shutdown_child(state(), child_name)
    store(state)
    :ok
  end

  def shutdown_all(reason) do
    state = Functional.shutdown_all(state(), reason)
    store(state)
    :ok
  end

  def handle_message(message) do
    with {result, state} <- Functional.handle_message(state(), message) do
      store(state)
      result
    end
  end

  def entries(), do: Functional.entries(state())

  def size(), do: Functional.size(state())

  def name(pid), do: Functional.name(state(), pid)

  def pid(name), do: Functional.pid(state(), name)

  defp state() do
    state = Process.get(__MODULE__)
    if is_nil(state), do: raise("#{__MODULE__} is not initialized")
    state
  end

  defp store(state), do: Process.put(__MODULE__, state)
end
