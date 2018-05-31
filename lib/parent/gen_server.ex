defmodule Parent.GenServer do
  use GenServer
  use Parent.PublicTypes

  @type state :: term

  @callback handle_child_terminated(id, child_meta, pid, reason :: term, state) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate}
              | {:stop, reason :: term, new_state}
            when new_state: state

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts, behaviour: __MODULE__] do
      use GenServer, opts
      @behaviour behaviour

      @doc """
      Returns a specification to start this module under a supervisor.
      See `Supervisor`.
      """
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          shutdown: :infinity
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @impl behaviour
      def handle_child_terminated(_id, _meta, _pid, _reason, state), do: {:noreply, state}

      defoverridable handle_child_terminated: 5, child_spec: 1
    end
  end

  @spec start_link(module, arg :: term, GenServer.options()) :: GenServer.on_start()
  def start_link(module, arg, options \\ []) do
    GenServer.start_link(__MODULE__, {module, arg}, options)
  end

  @spec start_child(child_spec | module | {module, term}) :: on_start_child
  defdelegate start_child(child_spec), to: Parent.Procdict

  @spec shutdown_child(id) :: :ok
  defdelegate shutdown_child(child_id), to: Parent.Procdict

  @spec children :: [child]
  defdelegate children(), to: Parent.Procdict, as: :entries

  @spec num_children() :: non_neg_integer
  defdelegate num_children(), to: Parent.Procdict, as: :size

  @spec child_id(pid) :: {:ok, id} | :error
  defdelegate child_id(pid), to: Parent.Procdict, as: :id

  @spec child_pid(id) :: {:ok, pid} | :error
  defdelegate child_pid(id), to: Parent.Procdict, as: :pid

  @spec child_meta(id) :: {:ok, child_meta} | :error
  defdelegate child_meta(id), to: Parent.Procdict, as: :meta

  @spec update_child_meta(id, (child_meta -> child_meta)) :: :ok | :error
  defdelegate update_child_meta(id, updater), to: Parent.Procdict, as: :update_meta

  @spec shutdown_all(reason :: term) :: :ok
  defdelegate shutdown_all(reason \\ :shutdown), to: Parent.Procdict

  @spec child?(id) :: boolean
  def child?(id), do: match?({:ok, _}, child_pid(id))

  @impl GenServer
  def init({callback, arg}) do
    Process.put({__MODULE__, :callback}, callback)
    Parent.Procdict.initialize()
    invoke_callback(:init, [arg])
  end

  @impl GenServer
  def handle_info(message, state) do
    case Parent.Procdict.handle_message(message) do
      {:EXIT, pid, id, meta, reason} ->
        invoke_callback(:handle_child_terminated, [id, meta, pid, reason, state])

      :error ->
        invoke_callback(:handle_info, [message, state])
    end
  end

  @impl GenServer
  def handle_call(message, from, state), do: invoke_callback(:handle_call, [message, from, state])

  @impl GenServer
  def handle_cast(message, state), do: invoke_callback(:handle_cast, [message, state])

  @impl GenServer
  def format_status(reason, pdict_and_state),
    do: invoke_callback(:format_status, [reason, pdict_and_state])

  @impl GenServer
  def code_change(old_vsn, state, extra),
    do: invoke_callback(:code_change, [old_vsn, state, extra])

  @impl GenServer
  def terminate(reason, state) do
    invoke_callback(:terminate, [reason, state])
  after
    Parent.Procdict.shutdown_all(reason)
  end

  defp invoke_callback(fun, arg), do: apply(Process.get({__MODULE__, :callback}), fun, arg)

  @doc false
  def child_spec(_arg) do
    raise("#{__MODULE__} can't be used in a child spec.")
  end
end
