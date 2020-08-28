defmodule Parent.State do
  @moduledoc false

  @opaque t :: %{
            id_to_pid: %{Parent.child_id() => pid},
            children: %{pid => child()},
            startup_index: non_neg_integer
          }

  @opaque child :: %{
            id: Parent.child_id(),
            pid: pid,
            shutdown: Parent.shutdown(),
            meta: Parent.child_meta(),
            type: :worker | :supervisor,
            modules: [module] | :dynamic,
            timer_ref: reference() | nil,
            startup_index: non_neg_integer()
          }

  @type on_handle_message :: {Parent.handle_message_response(), t} | nil

  @spec initialize() :: t
  def initialize(), do: %{id_to_pid: %{}, children: %{}, startup_index: 0}

  @spec children(t) :: [Parent.child()]
  def children(state) do
    Enum.map(state.children, fn {pid, child} -> {child.id, pid, child.meta} end)
  end

  @spec supervisor_which_children(t) :: [{term(), pid(), :worker, [module()] | :dynamic}]
  def supervisor_which_children(state) do
    Enum.map(
      state.children,
      fn {pid, child} -> {child.id, pid, child.type, child.modules} end
    )
  end

  @spec supervisor_count_children(t) :: [
          specs: non_neg_integer,
          active: non_neg_integer,
          supervisors: non_neg_integer,
          workers: non_neg_integer
        ]
  def supervisor_count_children(state) do
    Enum.reduce(
      state.children,
      %{specs: 0, active: 0, supervisors: 0, workers: 0},
      fn {_pid, child}, acc ->
        %{
          acc
          | specs: acc.specs + 1,
            active: acc.active + 1,
            workers: acc.workers + if(child.type == :worker, do: 1, else: 0),
            supervisors: acc.supervisors + if(child.type == :supervisor, do: 1, else: 0)
        }
      end
    )
    |> Map.to_list()
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

  @spec child_id(t, pid) :: {:ok, Parent.child_id()} | :error
  def child_id(state, pid) do
    with {:ok, child} <- Map.fetch(state.children, pid), do: {:ok, child.id}
  end

  @spec child_pid(t, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(state, id), do: Map.fetch(state.id_to_pid, id)

  @spec child_meta(t, Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(state, id) do
    with {:ok, pid} <- child_pid(state, id),
         {:ok, child} <- child(state, pid),
         do: {:ok, child.meta}
  end

  @spec update_child_meta(t, Parent.child_id(), (Parent.child_meta() -> Parent.child_meta())) ::
          {:ok, t} | :error
  def update_child_meta(state, id, updater) do
    with {:ok, pid} <- child_pid(state, id),
         do: update(state, pid, &update_in(&1.meta, updater))
  end

  @spec start_child(t, Parent.child_spec() | module | {module, term}) :: {:ok, pid, t} | term
  def start_child(state, child_spec) do
    full_child_spec = expand_child_spec(child_spec)

    with {:ok, pid} <- start_child_process(full_child_spec.start) do
      timer_ref =
        case full_child_spec.timeout do
          :infinity -> nil
          timeout -> Process.send_after(self(), {__MODULE__, :child_timeout, pid}, timeout)
        end

      child = %{
        id: full_child_spec.id,
        pid: pid,
        shutdown: full_child_spec.shutdown,
        meta: full_child_spec.meta,
        type: full_child_spec.type,
        modules: full_child_spec.modules,
        timer_ref: timer_ref,
        startup_index: state.startup_index
      }

      {:ok, pid, register(state, child)}
    end
  end

  @spec shutdown_child(t, Parent.child_id()) :: t
  def shutdown_child(state, child_id) do
    case child_pid(state, child_id) do
      :error -> raise "trying to terminate an unknown child"
      {:ok, pid} -> shutdown_child(state, pid, :shutdown)
    end
  end

  @spec handle_message(t, term) :: on_handle_message
  def handle_message(state, {:EXIT, pid, reason}) do
    case pop(state, pid) do
      {:ok, child, state} ->
        kill_timer(child.timer_ref, pid)
        {{:EXIT, pid, child.id, child.meta, reason}, state}

      :error ->
        nil
    end
  end

  def handle_message(state, {__MODULE__, :child_timeout, pid}) do
    child = Map.fetch!(state.children, pid)
    state = shutdown_child(state, pid, :kill)
    {{:EXIT, pid, child.id, child.meta, :timeout}, state}
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

  @spec await_child_termination(t, Parent.child_id(), non_neg_integer() | :infinity) ::
          {{pid, Parent.child_meta(), reason :: term}, t} | :timeout
  def await_child_termination(state, child_id, timeout) do
    case child_pid(state, child_id) do
      :error ->
        raise "unknown child"

      {:ok, pid} ->
        receive do
          {:EXIT, ^pid, reason} ->
            with {:ok, %{id: ^child_id} = child, state} <- pop(state, pid) do
              kill_timer(child.timer_ref, pid)
              {{pid, child.meta, reason}, state}
            end
        after
          timeout -> :timeout
        end
    end
  end

  @spec shutdown_all(t, term) :: t
  def shutdown_all(state, reason) do
    reason = with :normal <- reason, do: :shutdown

    state.children
    |> Enum.sort_by(fn {_pid, child} -> child.startup_index end, &>=/2)
    |> Enum.reduce(state, fn {pid, _child}, state -> shutdown_child(state, pid, reason) end)
  end

  defp shutdown_child(state, pid, reason) do
    {:ok, child} = child(state, pid)
    kill_timer(child.timer_ref, pid)

    exit_signal = if child.shutdown == :brutal_kill, do: :kill, else: reason
    wait_time = if exit_signal == :kill, do: :infinity, else: child.shutdown

    sync_stop_process(pid, exit_signal, wait_time)

    {:ok, _child, state} = pop(state, pid)
    state
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

  defp child(state, pid), do: Map.fetch(state.children, pid)

  defp register(state, %{id: id, pid: pid} = child) do
    if match?(%{children: %{^pid => _}}, state),
      do: raise("process #{inspect(pid)} is already registered")

    if match?(%{id_to_pid: %{^id => _}}, state),
      do: raise("id #{inspect(id)} is already taken")

    state
    |> put_in([:id_to_pid, id], pid)
    |> put_in([:children, pid], child)
    |> update_in([:startup_index], &(&1 + 1))
  end

  defp pop(state, pid) do
    with {:ok, child} <- Map.fetch(state.children, pid) do
      {:ok, child,
       state
       |> update_in([:id_to_pid], &Map.delete(&1, child.id))
       |> update_in([:children], &Map.delete(&1, pid))}
    end
  end

  defp update(state, pid, updater) do
    with {:ok, child} <- Map.fetch(state.children, pid),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, pid, updated_child),
         do: {:ok, %{state | children: updated_children}}
  end
end
