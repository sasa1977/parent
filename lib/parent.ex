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

  alias Parent.{ChildRegistry, State}

  @type opts :: [option]
  @type option :: {:restart, restart_limit}
  @type restart :: :temporary | :permanent | :transient | {:permanent | :transient, restart_limit}
  @type restart_limit :: [max_restarts: non_neg_integer | :infinity, max_seconds: pos_integer]

  @type child_spec :: %{
          :id => child_id,
          :start => start,
          optional(:modules) => [module] | :dynamic,
          optional(:type) => :worker | :supervisor,
          optional(:meta) => child_meta,
          optional(:shutdown) => shutdown,
          optional(:timeout) => pos_integer | :infinity,
          optional(:restart) => restart,
          optional(:binds_to) => [child_id],
          optional(:max_restarts) => {limit :: pos_integer, interval :: pos_integer} | :infinity,
          optional(:register?) => boolean,
          optional(:roles) => [child_role]
        }

  @type child_id :: term
  @type child_meta :: term
  @type child_role :: term

  @type start :: (() -> Supervisor.on_start_child()) | {module, atom, [term]}

  @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

  @type child :: %{id: child_id, pid: pid, meta: child_meta}

  @type handle_message_response ::
          {:child_terminated, child_termination_info}
          | {:child_restarted, child_restart_info}
          | :ignore

  @type child_termination_info :: %{
          id: child_id,
          pid: pid,
          meta: child_meta,
          reason: term,
          also_terminated: [also_terminated]
        }

  @type also_terminated :: %{id: child_id, pid: pid, meta: child_meta}

  @type child_restart_info :: %{
          id: child_id,
          reason: term,
          also_restarted: [child_id]
        }

  @doc """
  Initializes the state of the parent process.

  This function should be invoked once inside the parent process before other functions from this
  module are used. If a parent behaviour, such as `Parent.GenServer`, is used, this function must
  not be invoked.
  """
  @spec initialize(opts) :: :ok
  def initialize(opts \\ []) do
    if initialized?(), do: raise("Parent state is already initialized")
    Process.flag(:trap_exit, true)
    store(State.initialize(opts))
  end

  @doc "Returns true if the parent state is initialized."
  @spec initialized?() :: boolean
  def initialized?(), do: not is_nil(Process.get(__MODULE__))

  @doc "Starts the child described by the specification."
  @spec start_child(child_spec | module | {module, term}) :: Supervisor.on_start_child()
  def start_child(child_spec) do
    state = state()
    child_spec = expand_child_spec(child_spec)

    with :ok <- validate_id(state, child_spec.id),
         {:ok, pid, timer_ref} <- start_child_process(state, child_spec) do
      state = State.register_child(state, pid, child_spec, timer_ref)
      store(state)
      {:ok, pid}
    end
  end

  @doc """
  Returns the pid of the child of the given parent, or nil if such child or parent doesn't exist.

  This function can only find registered children, i.e. children which include `register?: true`
  in their child spec.

  This function can be invoked outside of the parent process.
  """
  @spec whereis_child(GenServer.server(), child_id) :: pid | nil
  defdelegate whereis_child(parent, child_id), to: ChildRegistry

  @doc false
  def whereis_name({parent, child_id}) do
    with nil <- whereis_child(parent, child_id), do: :undefined
  end

  @doc """
  Returns all the pids of the children of the given parent who are in the given role.

  This function can only find registered children, i.e. children which include `register?: true`
  in their child spec.

  This function can be invoked outside of the parent process.
  """
  @spec children_in_role(GenServer.server(), child_role) :: [pid]
  defdelegate children_in_role(parent, child_role), to: ChildRegistry

  @doc """
  Restarts the child.

  This function will also restart all non-temporary siblings and shut down all temporary siblings
  directly and transitively bound to the given child.

  If any child fails to restart, all of the children will be taken down and the parent process
  will exit.
  """
  @spec restart_child(child_id) :: restarted_children :: [child_id]
  def restart_child(child_id) do
    case State.pop_child_with_bound_siblings(state(), id: child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, children, state} ->
        children |> Enum.reverse() |> Enum.each(&stop_child(&1, :shutdown))
        state = Enum.reduce(children, state, &restart_child!(&2, &1))
        store(state)
        Enum.map(children, & &1.spec.id)
    end
  end

  @doc """
  Terminates the child.

  This function will also shut down all siblings directly and transitively bound to the given child.
  The function will wait for the child to terminate, and pull the `:EXIT` message from the mailbox.

  Permanent and transient children won't be restarted, and their specifications won't be preserved.
  In other words, this function completely removes the child and all other children bound to it.
  """
  @spec shutdown_child(child_id) :: terminated_children :: [child_id]
  def shutdown_child(child_id) do
    case State.pop_child_with_bound_siblings(state(), id: child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, children, state} ->
        children |> Enum.reverse() |> Enum.each(&stop_child(&1, :shutdown))
        store(state)
        Enum.map(children, & &1.spec.id)
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
    |> Enum.each(&stop_child(&1, reason))

    # initializing the state to reset the startup index
    store(State.reinitialize(state()))
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

  defp expand_child_spec(mod) when is_atom(mod), do: expand_child_spec({mod, nil})
  defp expand_child_spec({mod, arg}), do: expand_child_spec(mod.child_spec(arg))

  defp expand_child_spec(%{} = child_spec) do
    default_spec()
    |> Map.merge(default_type_and_shutdown_spec(Map.get(child_spec, :type, :worker)))
    |> Map.put(:modules, default_modules(child_spec.start))
    |> Map.merge(child_spec)
    |> Map.update!(:restart, &normalize_restart/1)
  end

  defp expand_child_spec(_other), do: raise("invalid child_spec")

  defp default_spec do
    %{
      meta: nil,
      timeout: :infinity,
      restart: :permanent,
      binds_to: [],
      register?: false,
      roles: []
    }
  end

  defp normalize_restart(:temporary), do: :temporary

  defp normalize_restart(type) when type in ~w/temporary permanent transient/a,
    do: normalize_restart({type, max_restarts: :infinity})

  defp normalize_restart({type, opts}),
    do: {type, Keyword.merge([max_restarts: :infinity, max_seconds: 5], opts)}

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

  defp start_child_process(state, child_spec) do
    with :ok <- check_bindings(state, child_spec),
         {:ok, pid} <- invoke_start_function(child_spec.start) do
      timer_ref =
        case child_spec.timeout do
          :infinity -> nil
          timeout -> Process.send_after(self(), {__MODULE__, :child_timeout, pid}, timeout)
        end

      if child_spec.register?, do: ChildRegistry.register(pid, child_spec)

      {:ok, pid, timer_ref}
    end
  end

  defp check_bindings(state, child_spec) do
    case Enum.filter(child_spec.binds_to, &(State.child(state, id: &1) == :error)) do
      [] -> :ok
      missing_deps -> {:error, {:missing_deps, missing_deps}}
    end
  end

  defp invoke_start_function({mod, fun, args}), do: apply(mod, fun, args)
  defp invoke_start_function(fun) when is_function(fun, 0), do: fun.()

  defp do_handle_message(state, {:EXIT, pid, reason}) do
    case State.child(state, pid: pid) do
      {:ok, child} ->
        kill_timer(child.timer_ref, pid)
        handle_child_down(state, child, reason)

      :error ->
        nil
    end
  end

  defp do_handle_message(state, {__MODULE__, :child_timeout, pid}) do
    child = State.child!(state, pid: pid)
    stop_child(child, :kill)
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
    {:ok, children, state} = State.pop_child_with_bound_siblings(state, pid: child.pid)
    bound_siblings = Enum.reject(children, &(&1.spec.id == child.spec.id))
    Enum.each(Enum.reverse(bound_siblings), &stop_child(&1, :shutdown))

    if requires_restart?(child, reason) do
      {child, state} = record_restart!(state, child)

      state =
        [child | bound_siblings]
        |> Enum.sort_by(& &1.startup_index)
        |> Enum.reduce(state, &restart_child!(&2, &1))

      info = %{
        id: child.spec.id,
        reason: reason,
        also_restarted: Enum.map(bound_siblings, & &1.spec.id)
      }

      {{:child_restarted, info}, state}
    else
      info = %{
        id: child.spec.id,
        pid: child.pid,
        meta: child.spec.meta,
        reason: reason,
        also_terminated: Enum.map(bound_siblings, &terminated_info/1)
      }

      {{:child_terminated, info}, state}
    end
  end

  defp record_restart!(state, child) do
    with {:ok, state} <- State.record_restart(state),
         {:ok, restart_counter} <- Parent.RestartCounter.record_restart(child.restart_counter) do
      {%{child | restart_counter: restart_counter}, state}
    else
      _ ->
        give_up!(state, :too_many_restarts, "Too many restarts in parent process.")
    end
  end

  defp give_up!(state, exit, error) do
    Logger.error(error)
    store(state)
    shutdown_all()
    exit(exit)
  end

  defp requires_restart?(%{spec: %{restart: :temporary}}, _reason), do: false
  defp requires_restart?(%{spec: %{restart: {:permanent, _opts}}}, _reason), do: true
  defp requires_restart?(%{spec: %{restart: {:transient, _opts}}}, reason), do: reason != :normal

  defp terminated_info(child), do: %{id: child.spec.id, pid: child.pid, meta: child.spec.meta}

  defp restart_child!(state, child) do
    case start_child_process(state, child.spec) do
      {:ok, new_pid, timer_ref} ->
        State.reregister_child(state, child, new_pid, timer_ref)

      error ->
        error = "Failed to restart child #{inspect(child.spec.id)}: #{inspect(error)}."
        give_up!(state, :restart_error, error)
    end
  end

  defp stop_child(child, reason) do
    kill_timer(child.timer_ref, child.pid)
    exit_signal = if child.spec.shutdown == :brutal_kill, do: :kill, else: reason
    wait_time = if exit_signal == :kill, do: :infinity, else: child.spec.shutdown
    sync_stop_process(child.pid, exit_signal, wait_time)
    if child.spec.register?, do: ChildRegistry.unregister(child.pid)
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