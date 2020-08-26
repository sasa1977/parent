defmodule Parent do
  @moduledoc false
  alias Parent.State
  use Parent.PublicTypes

  @doc """
  Initializes the state of the parent process.

  This function should be invoked once inside the parent process before other functions from this
  module are used. If a parent behaviour, such as `Parent.GenServer`, is used, this function must
  not be invoked.
  """
  @spec initialize() :: :ok
  def initialize() do
    if initialized?(), do: raise("Parent state is already initialized")
    Process.put(__MODULE__, State.initialize())
    :ok
  end

  @doc "Returns true if the parent state is initialized."
  @spec initialized?() :: boolean
  def initialized?(), do: not is_nil(Process.get(__MODULE__))

  @doc "Starts the child described by the specification."
  @spec start_child(child_spec | module | {module, term}) :: on_start_child
  def start_child(child_spec) do
    with result <- State.start_child(state(), child_spec),
         {:ok, pid, state} <- result do
      store(state)
      {:ok, pid}
    end
  end

  @doc """
  Terminates the child.

  This function waits for the child to terminate. In the case of explicit
  termination, `handle_child_terminated/5` will not be invoked.
  """
  @spec shutdown_child(id) :: :ok
  def shutdown_child(child_id) do
    state = State.shutdown_child(state(), child_id)
    store(state)
    :ok
  end

  @doc """
  Terminates all running child processes.

  Children are terminated synchronously, in the reverse order from the order they
  have been started in.
  """
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

  @doc """
  Awaits for the child to terminate.

  If the function succeeds, `handle_child_terminated/5` will not be invoked.
  """
  @spec await_child_termination(id, non_neg_integer() | :infinity) ::
          {pid, child_meta, reason :: term} | :timeout
  def await_child_termination(child_id, timeout) do
    with {result, state} <- State.await_child_termination(state(), child_id, timeout) do
      store(state)
      result
    end
  end

  @doc "Returns the list of running child processes."
  @spec children :: [child]
  def children(), do: State.children(state())

  @doc """
  Returns true if the child process is still running, false otherwise.

  Note that this function might return true even if the child has terminated.
  This can happen if the corresponding `:EXIT` message still hasn't been
  processed.
  """
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

  @doc "Returns the count of running child processes."
  @spec num_children() :: non_neg_integer
  def num_children(), do: State.num_children(state())

  @doc "Returns the id of a child process with the given pid."
  @spec child_id(pid) :: {:ok, id} | :error
  def child_id(pid), do: State.child_id(state(), pid)

  @doc "Returns the pid of a child process with the given id."
  @spec child_pid(id) :: {:ok, pid} | :error
  def child_pid(id), do: State.child_pid(state(), id)

  @doc "Returns the meta associated with the given child id."
  @spec child_meta(id) :: {:ok, child_meta} | :error
  def child_meta(id), do: State.child_meta(state(), id)

  @doc "Updates the meta of the given child process."
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
