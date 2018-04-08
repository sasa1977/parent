defmodule Parent.GenServer do
  use GenServer

  @callback handle_child_terminated(any, pid, any, any) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate}
              | {:stop, reason :: term, new_state}
            when new_state: term

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts, behaviour: __MODULE__] do
      use GenServer, opts
      @behaviour behaviour

      @impl behaviour
      def handle_child_terminated(_name, _pid, _reason, state), do: {:noreply, state}

      defoverridable handle_child_terminated: 4
    end
  end

  def start_link(module, arg, options \\ []) do
    GenServer.start_link(__MODULE__, {module, arg}, options)
  end

  defdelegate start_child(child_spec), to: Parent.Procdict

  defdelegate shutdown_child(child_name), to: Parent.Procdict

  defdelegate children(), to: Parent.Procdict, as: :entries

  defdelegate num_children(), to: Parent.Procdict, as: :size

  defdelegate child_name(pid), to: Parent.Procdict, as: :name

  defdelegate child_pid(name), to: Parent.Procdict, as: :pid

  defdelegate shutdown_all(reason \\ :shutdown), to: Parent.Procdict

  def child?(name), do: match?({:ok, _}, child_pid(name))

  @impl GenServer
  def init({callback, arg}) do
    Process.put({__MODULE__, :callback}, callback)
    Parent.Procdict.initialize()
    invoke_callback(:init, [arg])
  end

  @impl GenServer
  def handle_info(message, state) do
    case Parent.Procdict.handle_message(message) do
      {:EXIT, pid, name, reason} ->
        invoke_callback(:handle_child_terminated, [name, pid, reason, state])

      :error ->
        invoke_callback(:handle_info, [message, state])
    end
  end

  @impl GenServer
  def handle_call(message, from, state), do: invoke_callback(:handle_call, [message, from, state])

  @impl GenServer
  def handle_cast(message, state), do: invoke_callback(:handle_cast, [message, state])

  @impl GenServer
  def terminate(reason, state) do
    result = invoke_callback(:terminate, [reason, state])
    Parent.Procdict.shutdown_all(reason)
    result
  end

  defp invoke_callback(fun, arg), do: apply(Process.get({__MODULE__, :callback}), fun, arg)
end
