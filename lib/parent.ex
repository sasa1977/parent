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
  require Logger

  alias Parent.State

  @type child_spec :: %{
          :id => child_id,
          :start => start,
          optional(:modules) => [module] | :dynamic,
          optional(:type) => :worker | :supervisor,
          optional(:meta) => child_meta,
          optional(:shutdown) => shutdown,
          optional(:timeout) => pos_integer | :infinity,
          optional(:restart) => :permanent | :temporary | :transient
        }

  @type child_id :: term
  @type child_meta :: term

  @type start :: (() -> Supervisor.on_start_child()) | {module, atom, [term]}

  @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

  @type child :: %{id: child_id, pid: pid, meta: child_meta}

  @type handle_message_response ::
          {:child_terminated, child_termination_info}
          | {:child_restarted, child_restart_info}
          | :ignore

  @type child_termination_info :: %{id: child_id, pid: pid, meta: child_meta, reason: term}

  @type child_restart_info :: %{
          id: child_id,
          old_pid: pid,
          new_pid: pid,
          meta: child_meta,
          reason: term
        }

  @doc """
  Initializes the state of the parent process.

  This function should be invoked once inside the parent process before other functions from this
  module are used. If a parent behaviour, such as `Parent.GenServer`, is used, this function must
  not be invoked.
  """
  @spec initialize() :: :ok
  def initialize() do
    if initialized?(), do: raise("Parent state is already initialized")
    Process.flag(:trap_exit, true)
    store(State.initialize())
  end

  @doc "Returns true if the parent state is initialized."
  @spec initialized?() :: boolean
  def initialized?(), do: not is_nil(Process.get(__MODULE__))

  @doc "Starts the child described by the specification."
  @spec start_child(child_spec | module | {module, term}) :: Supervisor.on_start_child()
  def start_child(child_spec) do
    state = state()
    full_child_spec = expand_child_spec(child_spec)

    with :ok <- validate_id(state, full_child_spec.id),
         {:ok, pid, state} <- do_start_child(state, full_child_spec) do
      store(state)
      {:ok, pid}
    end
  end

  @doc "Restarts the child."
  @spec restart_child(child_id) :: Supervisor.on_start_child()
  def restart_child(child_id) do
    case State.child_pid(state(), child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, pid} ->
        {:ok, child, _state} = State.pop(state(), pid)
        shutdown_child(child_id)

        with {:ok, pid, state} <- do_start_child(state(), child.spec, child.startup_index) do
          store(state)
          {:ok, pid}
        end
    end
  end

  @doc """
  Terminates the child.

  This function waits for the child to terminate, and pulls the `:EXIT` message from the mailbox.
  """
  @spec shutdown_child(child_id) :: :ok
  def shutdown_child(child_id) do
    state = state()

    case State.child_pid(state, child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, pid} ->
        {:ok, child, state} = State.pop(state, pid)
        do_shutdown_child(child, :shutdown)
        store(state)
    end
  end

  @doc """
  Terminates all running child processes.

  Children are terminated synchronously, in the reverse order from the order they
  have been started in. All corresponding `:EXIT` messages will be pulled from the mailbox.
  """
  @spec shutdown_all(term) :: :ok
  def shutdown_all(reason \\ :shutdown) do
    reason = with :normal <- reason, do: :shutdown

    state()
    |> State.children()
    |> Enum.reverse()
    |> Enum.each(&do_shutdown_child(&1, reason))

    store(State.initialize())
  end

  @doc """
  Should be invoked by the parent process for each incoming message.

  If the given message is not handled, this function returns `nil`. In such cases, the client code
  should perform standard message handling. Otherwise, the message has been handled by the parent,
  and the client code doesn't shouldn't treat this message as a standard message (e.g. by calling
  `handle_info` of the callback module).

  However, in some cases, a client might want to do some special processing, so the return value
  will contain information which might be of interest to the client. Possible values are:

    - `{:child_terminated, info}` - a child process has terminated
    - `{:child_restarted, info}` - `Parent` handled this message, but there's no useful information to return

  See `t:handle_message_response/0` for detailed type specification of each message.

  Note that you don't need to invoke this function in a `Parent.GenServer` callback module.
  """
  @spec handle_message(term) :: handle_message_response() | nil
  def handle_message(message) do
    with {result, state} <- do_handle_message(state(), message) do
      store(state)
      result
    end
  end

  @doc """
  Awaits for the child to terminate.

  If the function succeeds, `handle_child_terminated/2` will not be invoked.
  """
  @spec await_child_termination(child_id, non_neg_integer() | :infinity) ::
          {pid, child_meta, reason :: term} | :timeout
  def await_child_termination(child_id, timeout) do
    state = state()

    case State.child_pid(state, child_id) do
      :error ->
        raise "unknown child"

      {:ok, pid} ->
        receive do
          {:EXIT, ^pid, reason} ->
            {:ok, %{spec: %{id: ^child_id}} = child, state} = State.pop(state, pid)
            kill_timer(child.timer_ref, pid)
            store(state)
            {pid, child.spec.meta, reason}
        after
          timeout -> :timeout
        end
    end
  end

  @doc "Returns the list of running child processes in the startup order."
  @spec children :: [child]
  def children(),
    do: Enum.map(State.children(state()), &%{id: &1.spec.id, pid: &1.pid, meta: &1.spec.meta})

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
  def supervisor_which_children() do
    state()
    |> State.children()
    |> Enum.map(&{&1.spec.id, &1.pid, &1.spec.type, &1.spec.modules})
  end

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
  def supervisor_count_children() do
    Enum.reduce(
      State.children(state()),
      %{specs: 0, active: 0, supervisors: 0, workers: 0},
      fn child, acc ->
        %{
          acc
          | specs: acc.specs + 1,
            active: acc.active + 1,
            workers: acc.workers + if(child.spec.type == :worker, do: 1, else: 0),
            supervisors: acc.supervisors + if(child.spec.type == :supervisor, do: 1, else: 0)
        }
      end
    )
    |> Map.to_list()
  end

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
    with {:ok, new_state} <- State.update_child_meta(state(), id, updater),
         do: store(new_state)
  end

  @default_spec %{meta: nil, timeout: :infinity, restart: :temporary}

  defp expand_child_spec(mod) when is_atom(mod), do: expand_child_spec({mod, nil})
  defp expand_child_spec({mod, arg}), do: expand_child_spec(mod.child_spec(arg))

  defp expand_child_spec(%{} = child_spec) do
    @default_spec
    |> Map.merge(default_type_and_shutdown_spec(Map.get(child_spec, :type, :worker)))
    |> Map.put(:modules, default_modules(child_spec.start))
    |> Map.merge(child_spec)
  end

  defp expand_child_spec(_other), do: raise("invalid child_spec")

  defp default_type_and_shutdown_spec(:worker), do: %{type: :worker, shutdown: :timer.seconds(5)}
  defp default_type_and_shutdown_spec(:supervisor), do: %{type: :supervisor, shutdown: :infinity}

  defp default_modules({mod, _fun, _args}), do: [mod]

  defp default_modules(fun) when is_function(fun),
    do: [fun |> :erlang.fun_info() |> Keyword.fetch!(:module)]

  defp validate_id(state, id) do
    case State.child_pid(state, id) do
      {:ok, pid} -> {:error, {:already_started, pid}}
      :error -> :ok
    end
  end

  defp do_start_child(state, full_child_spec, startup_index \\ nil) do
    with {:ok, pid} <- start_child_process(full_child_spec.start) do
      timer_ref =
        case full_child_spec.timeout do
          :infinity -> nil
          timeout -> Process.send_after(self(), {__MODULE__, :child_timeout, pid}, timeout)
        end

      state = State.register_child(state, pid, full_child_spec, timer_ref, startup_index)

      {:ok, pid, state}
    end
  end

  defp start_child_process({mod, fun, args}), do: apply(mod, fun, args)
  defp start_child_process(fun) when is_function(fun, 0), do: fun.()

  defp do_handle_message(state, {:EXIT, pid, reason}) do
    case State.pop(state, pid) do
      {:ok, child, state} ->
        kill_timer(child.timer_ref, pid)
        handle_child_down(state, child, reason)

      :error ->
        nil
    end
  end

  defp do_handle_message(state, {__MODULE__, :child_timeout, pid}) do
    {:ok, child, state} = State.pop(state, pid)
    do_shutdown_child(child, :kill)
    handle_child_down(state, child, :timeout)
  end

  defp do_handle_message(state, {:"$gen_call", client, :which_children}) do
    GenServer.reply(client, supervisor_which_children())
    {:ignore, state}
  end

  defp do_handle_message(state, {:"$gen_call", client, :count_children}) do
    GenServer.reply(client, supervisor_count_children())
    {:ignore, state}
  end

  defp do_handle_message(_state, _other), do: nil

  defp handle_child_down(state, child, reason) do
    if child.spec.restart == :temporary or
         (child.spec.restart == :transient and reason == :normal) do
      {{:EXIT, child.pid, child.spec.id, child.spec.meta, reason}, state}
      info = %{id: child.spec.id, pid: child.pid, meta: child.spec.meta, reason: reason}
      {{:child_terminated, info}, state}
    else
      case do_start_child(state, child.spec, child.startup_index) do
        {:ok, new_pid, state} ->
          info = %{
            id: child.spec.id,
            old_pid: child.pid,
            new_pid: new_pid,
            meta: child.spec.meta,
            reason: reason
          }

          {{:child_restarted, info}, state}

        _error ->
          Logger.error(
            "Failed to restart the child #{inspect(child.spec.id)}. Parent is terminating."
          )

          store(state)
          shutdown_all()
          exit(:restart_error)
      end
    end
  end

  defp do_shutdown_child(child, reason) do
    kill_timer(child.timer_ref, child.pid)

    exit_signal = if child.spec.shutdown == :brutal_kill, do: :kill, else: reason
    wait_time = if exit_signal == :kill, do: :infinity, else: child.spec.shutdown

    sync_stop_process(child.pid, exit_signal, wait_time)
  end

  defp sync_stop_process(pid, exit_signal, wait_time) do
    Process.exit(pid, exit_signal)

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      wait_time ->
        Process.exit(pid, :kill)

        receive do
          {:EXIT, ^pid, _reason} -> :ok
        end
    end
  end

  defp kill_timer(nil, _pid), do: :ok

  defp kill_timer(timer_ref, pid) do
    Process.cancel_timer(timer_ref)

    receive do
      {Parent, :child_timeout, ^pid} -> :ok
    after
      0 -> :ok
    end
  end

  @spec state() :: State.t()
  defp state() do
    state = Process.get(__MODULE__)
    if is_nil(state), do: raise("Parent is not initialized")
    state
  end

  @spec store(State.t()) :: :ok
  defp store(state) do
    Process.put(__MODULE__, state)
    :ok
  end
end
