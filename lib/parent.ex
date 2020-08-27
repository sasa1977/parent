defmodule Parent do
  @moduledoc """
  Functions for implementing a parent process.

  A parent process has the following properties:

  1. It traps exits.
  2. It tracks its children inside the process dictionary.
  3. Before terminating, it stops its children synchronously, in the reverse startup order.

  In most cases the simplest option is to start a parent process using a higher-level abstraction
  such as `Parent.GenServer`. In this case you will use a subset of the API from this module to
  start, stop, and enumerate your children.

  If available parent behaviours don't fit your purposes, you can consider building your own
  behaviour or a concrete process. In this case, the functions of this module will provide the
  necessary plumbing. To implement a parent process you need to do the following:

  1. Invoke `initialize/0` when the process is started.
  2. Use functions such as `start_child/1` to work with child processes.
  3. When a message is received, invoke `handle_message/1` before handling the message yourself.
  4. If you receive a shutdown exit message from your parent, stop the process.
  5. Before terminating, invoke `shutdown_all/1` to stop all the children.
  6. Use `:infinity` as the shutdown strategy for the parent process, and `:supervisor` for its type.
  7. If the process is a `GenServer`, handle supervisor calls (see `supervisor_which_children/0`
     and `supervisor_count_children/0`).
  8. Implement `format_status/2` (see `Parent.GenServer` for details) where applicable.

  If the parent process is powered by a non-interactive code (e.g. `Task`), make sure
  to receive messages sent to that process, and handle them properly (see points 3 and 4).

  You can take a look at the code of `Parent.GenServer` for specific details.
  """
  alias Parent.State

  @type child_spec :: %{
          :id => child_id,
          :start => start,
          optional(:modules) => [module] | :dynamic,
          optional(:type) => :worker | :supervisor,
          optional(:meta) => child_meta,
          optional(:shutdown) => shutdown,
          optional(:timeout) => pos_integer | :infinity
        }

  @type child_id :: term
  @type child_meta :: term

  @type start :: (() -> on_start_child) | {module, atom, [term]}
  @type on_start_child :: on_start_child

  @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

  @type child :: {child_id, pid, child_meta}

  @type handle_message_response :: {:EXIT, pid, child_id, child_meta, reason :: term} | :ignore

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
  @spec shutdown_child(child_id) :: :ok
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

  @doc """
  Should be invoked by the parent process for each incoming message.

  If the given message is not handled, this function returns `nil`. In such cases, the client code
  should perform standard message handling. Otherwise, the message has been handled by the parent,
  and the client code doesn't shouldn't treat this message as a standard message (e.g. by calling
  `handle_info` of the callback module).

  However, in some cases, a client might want to do some special processing, so the return value
  will contain information which might be of interest to the client. Possible values are:

    - `{:EXIT, pid, id, child_meta, reason :: term}` - a child process has terminated
    - `:ignore` - `Parent` handled this message, but there's no useful information to return

  Note that you don't need to invoke this function in a `Parent.GenServer` callback module.
  """
  @spec handle_message(term) :: handle_message_response() | nil
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
  @spec await_child_termination(child_id, non_neg_integer() | :infinity) ::
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
  @spec child?(child_id) :: boolean
  def child?(id), do: match?({:ok, _}, child_pid(id))

  @doc """
  Should be invoked by the behaviour when handling `:which_children` GenServer call.

  You only need to invoke this function if you're implementing a parent process using a behaviour
  which forwards `GenServer` call messages to the `handle_call` callback. In such cases you need
  to respond to the client with the result of this function. Note that parent behaviours such as
  `Parent.GenServer` will do this automatically.

  If no translation of `GenServer` messages is taking place, i.e. if you're handling all messages
  in their original shape, this function will be invoked through `handle_message/1`.
  """
  @spec supervisor_which_children() :: [{term(), pid(), :worker, [module()] | :dynamic}]
  def supervisor_which_children(), do: State.supervisor_which_children(state())

  @doc """
  Should be invoked by the behaviour when handling `:count_children` GenServer call.

  See `supervisor_which_children/0` for details.
  """
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
  @spec child_id(pid) :: {:ok, child_id} | :error
  def child_id(pid), do: State.child_id(state(), pid)

  @doc "Returns the pid of a child process with the given id."
  @spec child_pid(child_id) :: {:ok, pid} | :error
  def child_pid(id), do: State.child_pid(state(), id)

  @doc "Returns the meta associated with the given child id."
  @spec child_meta(child_id) :: {:ok, child_meta} | :error
  def child_meta(id), do: State.child_meta(state(), id)

  @doc "Updates the meta of the given child process."
  @spec update_child_meta(child_id, (child_meta -> child_meta)) :: :ok | :error
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
