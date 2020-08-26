defmodule Parent do
  @moduledoc false
  alias Parent.State
  use Parent.PublicTypes

  @spec initialize() :: :ok
  def initialize() do
    if initialized?(), do: raise("Parent state is already initialized")
    Process.put(__MODULE__, State.initialize())
    :ok
  end

  @spec initialized?() :: boolean
  def initialized?(), do: not is_nil(Process.get(__MODULE__))

  @spec start_child(child_spec | module | {module, term}) :: on_start_child
  def start_child(child_spec) do
    with result <- State.start_child(state(), child_spec),
         {:ok, pid, state} <- result do
      store(state)
      {:ok, pid}
    end
  end

  @spec shutdown_child(id) :: :ok
  def shutdown_child(child_id) do
    state = State.shutdown_child(state(), child_id)
    store(state)
    :ok
  end

  @spec shutdown_all(term) :: :ok
  def shutdown_all(reason) do
    state = State.shutdown_all(state(), reason)
    store(state)
    :ok
  end

  @spec handle_message(term) :: State.child_exit_message() | :error | :ignore
  def handle_message(message) do
    with {result, state} <- State.handle_message(state(), message) do
      store(state)
      result
    end
  end

  @spec await_child_termination(id, non_neg_integer() | :infinity) ::
          {pid, child_meta, reason :: term} | :timeout
  def await_child_termination(child_id, timeout) do
    with {result, state} <- State.await_child_termination(state(), child_id, timeout) do
      store(state)
      result
    end
  end

  @spec children :: [child]
  def children(), do: State.children(state())

  @spec child?(id) :: boolean
  def child?(id), do: match?({:ok, _}, child_pid(id))

  @spec supervisor_which_children() :: [{term(), pid(), :worker, [module()] | :dynamic}]
  def supervisor_which_children(), do: State.supervisor_which_children(state())

  @spec supervisor_count_children() :: [
          specs: non_neg_integer,
          active: non_neg_integer,
          supervisors: non_neg_integer,
          workers: non_neg_integer
        ]
  def supervisor_count_children(), do: State.supervisor_count_children(state())

  @spec num_children() :: non_neg_integer
  def num_children(), do: State.num_children(state())

  @spec child_id(pid) :: {:ok, id} | :error
  def child_id(pid), do: State.child_id(state(), pid)

  @spec child_pid(id) :: {:ok, pid} | :error
  def child_pid(id), do: State.child_pid(state(), id)

  @spec child_meta(id) :: {:ok, child_meta} | :error
  def child_meta(id), do: State.child_meta(state(), id)

  @spec update_child_meta(id, (child_meta -> child_meta)) :: :ok | :error
  def update_child_meta(id, updater) do
    with {:ok, new_state} <- State.update_child_meta(state(), id, updater) do
      store(new_state)
      :ok
    end
  end

  @spec state() :: State.t()
  defp state() do
    state = Process.get(__MODULE__)
    if is_nil(state), do: raise("#{__MODULE__} is not initialized")
    state
  end

  defp store(state), do: Process.put(__MODULE__, state)
end
