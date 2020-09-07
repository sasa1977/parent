defmodule Parent.GenServer do
  @moduledoc """
  GenServer with parenting capabilities powered by `Parent`.

  This behaviour can be useful in situations where `Parent.Supervisor` won't suffice.

  ## Example

  The following example is roughly similar to a standard
  [callback-based Supervisor](https://hexdocs.pm/elixir/Supervisor.html#module-module-based-supervisors):

      defmodule MyApp.Supervisor do
        # Automatically defines child_spec/1
        use Parent.GenServer

        def start_link(init_arg),
          do: Parent.GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

        @impl GenServer
        def init(_init_arg) do
          Parent.start_all_children!(children)
          {:ok, initial_state}
        end
      end

  The expression `use Parent.GenServer` will also inject `use GenServer` into your code. Your
  parent process is a GenServer, and this behaviour doesn't try to hide it. Except when starting
  the process, you work with the parent exactly as you work with any GenServer, using the same
  functions, such as `GenServer.call/3`, and providing the same callbacks, such as `init/1`, or
  `handle_call/3`.

  ## Interacting with the parent from the outside

  You can issue regular `GenServer` calls and casts, and send messages to the parent, which can
  be handled by corresponding `GenServer` callbacks. In addition, you can use functions from
  the `Parent.Client` module to manipulate or query the parent state from other processes. As a
  good practice, it's advised to wrap such invocations in the module which implements
  `Parent.GenServer`.

  ## Interacting with children inside the parent

  From within the parent process, you can interact with the child processes using functions from
  the `Parent` module. All child processes should be started using `Parent` functions, such as
  `Parent.start_child/1`, because otherwise `Parent` won't be aware of these processes and won't
  be able to fulfill its guarantees.

  Note that you can start children from any callback, not just during `init/1`. In addition, you
  don't need to start all children at once. Therefore, `Parent.GenServer` can prove useful when
  you need to make some runtime decisions:

        {:ok, child1} = Parent.start_child(child1_spec)

        if some_condition_met?,
          do: Parent.start_child(child2_spec)

        Parent.start_child(child3_spec)

  However, bear in mind that this code won't be executed again if the processes are restarted.

  ## Handling child termination

  If a child process terminates and isn't restarted, the `c:handle_child_terminated/2` callback is
  invoked. The default implementation does nothing.

  The following example uses `c:handle_child_terminated/2` to start a child task and report if it
  it crashes:

        defmodule MyJob do
          use Parent.GenServer, restart: :temporary

          def start_link(arg), do: Parent.GenServer.start_link(__MODULE__, arg)

          @impl GenServer
          def init(_) do
            {:ok, _} = Parent.start_child(%{
              start: {Task, :start_link, [fn -> job(arg) end]},
              restart: :temporary
            })
            {:ok, nil}
          end

          @impl Parent.GenServer
          def handle_child_terminated(info, state) do
            if info.reason != :normal do
              # report job failure
            end

            {:stop, reason, state}
          end
        end

  `handle_child_terminated` can be useful to implement arbitrary custom behaviour, such as
  restarting after a delay, and using incremental backoff periods between two consecutive starts.

  For example, this is how you could introduce a delay between two consecutive starts:

      def handle_child_terminated(info, state) do
        Process.send_after(self, {:restart, info.return_info}, delay)
        {:noreply, state}
      end

      def handle_info({:restart, return_info}, state) do
        Parent.return_children(return_info)
        {:noreply, state}
      end

  Keep in mind that `handle_child_terminated` is only invoked if the child crashed on its own,
  and if it's not going to be restarted.

  If the child was explicitly stopped via a `Parent` function, such as `Parent.shutdown_child/1`,
  this callback will not be invoked. The same holds for `Parent.Client` functions. If you want
  to unconditionally react to a termination of a child process, setup a monitor with `Process.monitor`
  and add a corresponding `handle_info` clause.

  If the child was taken down because its lifecycle is bound to some other process, the
  corresponding `handle_child_terminated` won't be invoked. For example, if process A is bound to
  process B, and process B crashes, only one `handle_child_terminated` will be invoked (for the
  crash of process B). However, the corresponding `info` will contain the list of all associated
  siblings that have been taken down, and `return_info` will include information necessary to
  restart all of these siblings. Refer to `Parent` documentation for details on lifecycles binding.

  ## Parent termination

  The behaviour takes down the child processes before it terminates, to ensure that no child
  process is running after the parent has terminated. The children are terminated synchronously,
  one by one, in the reverse start order.

  The termination of the children is done after the `terminate/1` callback returns. Therefore in
  `terminate/1` the child processes are still running, and you can interact with them, and even
  start additional children.

  ## Caveats

  Like any other `Parent`-based process, `Parent.GenServer` traps exits and uses the `:infinity`
  shutdown strategy. As a result, a parent process which blocks for a long time (e.g. because its
  communicating with a remote service) won't be able to handle child termination, and your
  fault-tolerance might be badly affected. In addition, a blocking parent might completely paralyze
  the system (or a subtree) shutdown. Setting a shutdown strategy to a finite time is a hacky
  workaround that will lead to lingering orphan processes, and might cause some strange race
  conditions which will be very hard to debug.

  Therefore, be wary of having too much logic inside a parent process. Try to push as much
  responsibilities as possible to other processes, such as children or siblings, and use parent
  only for coordination and reporting tasks.

  Finally, since parent trap exits, it's possible to receive an occasional stray `:EXIT` message
  if the child crashes during its initialization.
  """
  use GenServer

  @type state :: term
  @type options :: [Parent.option() | GenServer.option()]

  @doc """
  Invoked when a child has terminated.

  This callback will not be invoked in the following cases:

    - a child is terminated by invoking `Parent` functions such as `Parent.shutdown_child/1`
    - a child is implicitly terminated by `Parent` because its dependency has stopped
    - a child is restarted
  """
  @callback handle_child_terminated(info :: Parent.child_termination_info(), state) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate}
              | {:stop, reason :: term, new_state}
            when new_state: state

  @doc "Starts the parent process."
  @spec start_link(module, arg :: term, options) :: GenServer.on_start()
  def start_link(module, arg, options \\ []) do
    {parent_opts, gen_server_opts} =
      Keyword.split(options, ~w/max_restarts max_seconds registry?/a)

    GenServer.start_link(__MODULE__, {module, arg, parent_opts}, gen_server_opts)
  end

  @impl GenServer
  def init({callback, arg, options}) do
    # needed to simulate a supervisor
    Process.put(:"$initial_call", {:supervisor, callback, 1})

    Process.put({__MODULE__, :callback}, callback)
    Parent.initialize(options)
    invoke_callback(:init, [arg])
  end

  @impl GenServer
  def handle_info(message, state) do
    case Parent.handle_message(message) do
      {:child_terminated, info} ->
        invoke_callback(:handle_child_terminated, [info, state])

      :ignore ->
        {:noreply, state}

      nil ->
        invoke_callback(:handle_info, [message, state])
    end
  end

  @impl GenServer
  def handle_call(:which_children, _from, state),
    do: {:reply, Parent.supervisor_which_children(), state}

  def handle_call(:count_children, _from, state),
    do: {:reply, Parent.supervisor_count_children(), state}

  def handle_call({:get_childspec, child_id_or_pid}, _from, state),
    do: {:reply, Parent.supervisor_get_childspec(child_id_or_pid), state}

  def handle_call(message, from, state), do: invoke_callback(:handle_call, [message, from, state])

  @impl GenServer
  def handle_cast(message, state), do: invoke_callback(:handle_cast, [message, state])

  @impl GenServer
  # Needed to support `:supervisor.get_callback_module`
  def format_status(:normal, [_pdict, state]) do
    [
      data: [{~c"State", state}],
      supervisor: [{~c"Callback", Process.get({__MODULE__, :callback})}]
    ]
  end

  def format_status(:terminate, pdict_and_state),
    do: invoke_callback(:format_status, [:terminate, pdict_and_state])

  @impl GenServer
  def code_change(old_vsn, state, extra),
    do: invoke_callback(:code_change, [old_vsn, state, extra])

  @impl GenServer
  def terminate(reason, state) do
    invoke_callback(:terminate, [reason, state])
  after
    Parent.shutdown_all(reason)
  end

  unless Version.compare(System.version(), "1.7.0") == :lt do
    @impl GenServer
    def handle_continue(continue, state), do: invoke_callback(:handle_continue, [continue, state])
  end

  defp invoke_callback(fun, arg), do: apply(Process.get({__MODULE__, :callback}), fun, arg)

  @doc false
  def child_spec(_arg) do
    raise("#{__MODULE__} can't be used in a child spec.")
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts, behaviour: __MODULE__] do
      use GenServer, opts
      @behaviour behaviour

      @doc """
      Returns a specification to start this module under a supervisor.
      See `Supervisor`.
      """
      def child_spec(arg) do
        default = Parent.parent_spec(id: __MODULE__, start: {__MODULE__, :start_link, [arg]})
        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @impl behaviour
      def handle_child_terminated(_info, state), do: {:noreply, state}

      defoverridable handle_child_terminated: 2, child_spec: 1
    end
  end
end
