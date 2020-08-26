defmodule Parent.State do
  @moduledoc false
  alias Parent.Registry
  use Parent.PublicTypes

  @opaque t :: %{registry: Registry.t(), startup_index: non_neg_integer}
  @type on_handle_message :: {handle_message_response, t} | nil
  @type handle_message_response :: {:EXIT, pid, id, child_meta, reason :: term} | :ignore

  @spec initialize() :: t
  def initialize() do
    Process.flag(:trap_exit, true)
    %{registry: Registry.new(), startup_index: 0}
  end

  @spec children(t) :: [child]
  def children(state) do
    state.registry
    |> Registry.entries()
    |> Enum.map(fn {pid, process} -> {process.id, pid, process.data.meta} end)
  end

  @spec supervisor_which_children(t) :: [{term(), pid(), :worker, [module()] | :dynamic}]
  def supervisor_which_children(state) do
    Enum.map(Registry.entries(state.registry), fn {pid, process} ->
      {process.id, pid, process.data.type, process.data.modules}
    end)
  end

  @spec supervisor_count_children(t) :: [
          specs: non_neg_integer,
          active: non_neg_integer,
          supervisors: non_neg_integer,
          workers: non_neg_integer
        ]
  def supervisor_count_children(state) do
    Enum.reduce(
      Registry.entries(state.registry),
      %{specs: 0, active: 0, supervisors: 0, workers: 0},
      fn {_pid, process}, acc ->
        %{
          acc
          | specs: acc.specs + 1,
            active: acc.active + 1,
            workers: acc.workers + if(process.data.type == :worker, do: 1, else: 0),
            supervisors: acc.supervisors + if(process.data.type == :supervisor, do: 1, else: 0)
        }
      end
    )
    |> Map.to_list()
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Registry.size(state.registry)

  @spec child_id(t, pid) :: {:ok, id} | :error
  def child_id(state, pid), do: Registry.id(state.registry, pid)

  @spec child_pid(t, id) :: {:ok, pid} | :error
  def child_pid(state, id), do: Registry.pid(state.registry, id)

  @spec child_meta(t, id) :: {:ok, child_meta} | :error
  def child_meta(state, id) do
    with {:ok, pid} <- Registry.pid(state.registry, id),
         {:ok, data} <- Registry.data(state.registry, pid),
         do: {:ok, data.meta}
  end

  @spec update_child_meta(t, id, (child_meta -> child_meta)) :: {:ok, t} | :error
  def update_child_meta(state, id, updater) do
    with {:ok, pid} <- Registry.pid(state.registry, id),
         {:ok, updated_registry} <-
           Registry.update(state.registry, pid, &update_in(&1.meta, updater)),
         do: {:ok, %{state | registry: updated_registry}}
  end

  @spec start_child(t, child_spec | module | {module, term}) :: {:ok, pid, t} | term
  def start_child(state, child_spec) do
    full_child_spec = expand_child_spec(child_spec)

    with {:ok, pid} <- start_child_process(full_child_spec.start) do
      timer_ref =
        case full_child_spec.timeout do
          :infinity -> nil
          timeout -> Process.send_after(self(), {__MODULE__, :child_timeout, pid}, timeout)
        end

      data = %{
        shutdown: full_child_spec.shutdown,
        meta: full_child_spec.meta,
        type: full_child_spec.type,
        modules: full_child_spec.modules,
        timer_ref: timer_ref,
        startup_index: state.startup_index
      }

      registry = Registry.register(state.registry, full_child_spec.id, pid, data)

      {:ok, pid, %{state | registry: registry, startup_index: state.startup_index + 1}}
    end
  end

  @spec shutdown_child(t, id) :: t
  def shutdown_child(state, child_id) do
    case Registry.pid(state.registry, child_id) do
      :error -> raise "trying to terminate an unknown child"
      {:ok, pid} -> shutdown_child(state, pid, :shutdown)
    end
  end

  @spec handle_message(t, term) :: on_handle_message
  def handle_message(state, {:EXIT, pid, reason}) do
    case Registry.pop(state.registry, pid) do
      {:ok, id, data, registry} ->
        kill_timer(data.timer_ref, pid)
        {{:EXIT, pid, id, data.meta, reason}, %{state | registry: registry}}

      :error ->
        nil
    end
  end

  def handle_message(state, {__MODULE__, :child_timeout, pid}) do
    child = Map.fetch!(Registry.entries(state.registry), pid)
    state = shutdown_child(state, pid, :kill)
    {{:EXIT, pid, child.id, child.data.meta, :timeout}, state}
  end

  def handle_message(state, {:"$gen_call", client, :which_children}) do
    GenServer.reply(client, supervisor_which_children(state))
    {:ignore, state}
  end

  def handle_message(state, {:"$gen_call", client, :count_children}) do
    GenServer.reply(client, supervisor_count_children(state))
    {:ignore, state}
  end

  def handle_message(_state, _other), do: nil

  @spec await_child_termination(t, id, non_neg_integer() | :infinity) ::
          {{pid, child_meta, reason :: term}, t} | :timeout
  def await_child_termination(state, child_id, timeout) do
    case Registry.pid(state.registry, child_id) do
      :error ->
        raise "unknown child"

      {:ok, pid} ->
        receive do
          {:EXIT, ^pid, reason} ->
            with {:ok, ^child_id, data, registry} <- Registry.pop(state.registry, pid) do
              kill_timer(data.timer_ref, pid)
              {{pid, data.meta, reason}, %{state | registry: registry}}
            end
        after
          timeout -> :timeout
        end
    end
  end

  @spec shutdown_all(t, term) :: t
  def shutdown_all(state, reason) do
    reason = with :normal <- reason, do: :shutdown

    state.registry
    |> Registry.entries()
    |> Enum.sort_by(fn {_pid, process} -> process.data.startup_index end, &>=/2)
    |> Enum.reduce(state, fn {pid, _process}, state -> shutdown_child(state, pid, reason) end)
  end

  defp shutdown_child(state, pid, reason) do
    {:ok, data} = Registry.data(state.registry, pid)
    kill_timer(data.timer_ref, pid)

    exit_signal = if data.shutdown == :brutal_kill, do: :kill, else: reason
    wait_time = if exit_signal == :kill, do: :infinity, else: data.shutdown

    sync_stop_process(pid, exit_signal, wait_time)

    {:ok, _id, _data, registry} = Registry.pop(state.registry, pid)
    %{state | registry: registry}
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

  @default_spec %{meta: nil, timeout: :infinity}

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

  defp start_child_process({mod, fun, args}), do: apply(mod, fun, args)
  defp start_child_process(fun) when is_function(fun, 0), do: fun.()

  defp kill_timer(nil, _pid), do: :ok

  defp kill_timer(timer_ref, pid) do
    Process.cancel_timer(timer_ref)

    receive do
      {__MODULE__, :child_timeout, ^pid} -> :ok
    after
      0 -> :ok
    end
  end
end
