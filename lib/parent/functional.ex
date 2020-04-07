defmodule Parent.Functional do
  @moduledoc false
  alias Parent.Registry
  use Parent.PublicTypes

  @opaque t :: %{registry: Registry.t()}
  @type on_handle_message :: {child_exit_message, t} | :error | :ignore
  @type child_exit_message :: {:EXIT, pid, id, child_meta, reason :: term}

  @spec initialize() :: t
  def initialize() do
    Process.flag(:trap_exit, true)
    %{registry: Registry.new()}
  end

  @spec entries(t) :: [child]
  def entries(state) do
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

  @spec size(t) :: non_neg_integer
  def size(state), do: Registry.size(state.registry)

  @spec id(t, pid) :: {:ok, id} | :error
  def id(state, pid), do: Registry.id(state.registry, pid)

  @spec pid(t, id) :: {:ok, pid} | :error
  def pid(state, id), do: Registry.pid(state.registry, id)

  @spec meta(t, id) :: {:ok, child_meta} | :error
  def meta(state, id) do
    with {:ok, pid} <- Registry.pid(state.registry, id),
         {:ok, data} <- Registry.data(state.registry, pid),
         do: {:ok, data.meta}
  end

  @spec update_meta(t, id, (child_meta -> child_meta)) :: {:ok, t} | :error
  def update_meta(state, id, updater) do
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
        startup_index: System.unique_integer([:monotonic])
      }

      {:ok, pid, update_in(state.registry, &Registry.register(&1, full_child_spec.id, pid, data))}
    end
  end

  @spec shutdown_child(t, id) :: t
  def shutdown_child(state, child_id) do
    case Registry.pid(state.registry, child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, pid} ->
        {:ok, data} = Registry.data(state.registry, pid)
        shutdown = data.shutdown
        exit_reason = if shutdown == :brutal_kill, do: :kill, else: :shutdown
        wait_time = if shutdown == :brutal_kill, do: :infinity, else: shutdown

        Process.exit(pid, exit_reason)

        receive do
          {:EXIT, ^pid, _reason} -> :ok
        after
          wait_time ->
            Process.exit(pid, :kill)

            receive do
              {:EXIT, ^pid, _reason} -> :ok
            end
        end

        {:ok, _id, data, registry} = Registry.pop(state.registry, pid)
        kill_timer(data.timer_ref, pid)
        %{state | registry: registry}
    end
  end

  @spec handle_message(t, term) :: on_handle_message
  def handle_message(state, {:EXIT, pid, reason}) do
    with {:ok, id, data, registry} <- Registry.pop(state.registry, pid) do
      kill_timer(data.timer_ref, pid)
      {{:EXIT, pid, id, data.meta, reason}, %{state | registry: registry}}
    end
  end

  def handle_message(state, {__MODULE__, :child_timeout, pid}) do
    case Registry.pop(state.registry, pid) do
      {:ok, id, data, registry} ->
        Process.exit(pid, :kill)

        receive do
          {:EXIT, ^pid, _reason} -> :ok
        end

        {{:EXIT, pid, id, data.meta, :timeout}, %{state | registry: registry}}

      :error ->
        # The timeout has occurred, just after the child terminated. Since this
        # is still an internal message, we'll just ignore it.
        :ignore
    end
  end

  def handle_message(_state, _other), do: :error

  @spec await_termination(t, id, non_neg_integer() | :infinity) ::
          {{pid, child_meta, reason :: term}, t} | :timeout
  def await_termination(state, child_id, timeout) do
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
    state = terminate_all_children(state, shutdown_reason(reason))

    %{state | registry: Registry.new()}
  end

  defp terminate_all_children(state, reason) do
    pids_and_specs =
      state.registry
      |> Registry.entries()
      |> Enum.sort_by(fn {_pid, process} -> process.data.startup_index end, &>=/2)

    await_child_termination(state, pids_and_specs, reason)
  end

  defp stop_process({pid, %{data: %{shutdown: :brutal_kill}}}, _), do: Process.exit(pid, :kill)
  defp stop_process({pid, _spec}, reason), do: Process.exit(pid, reason)

  defp await_child_termination(state, [], _reason), do: state

  defp await_child_termination(state, [{pid, process} | other], reason) do
    # Kill all timeout timers first, because we don't want timeout to interfere with the shutdown logic.
    kill_timer(process.data.timer_ref, pid)

    stop_process({pid, process}, reason)
    start_time = :erlang.monotonic_time(:millisecond)

    receive do
      {:EXIT, ^pid, _reason} ->
        {:ok, _id, _data, registry} = Registry.pop(state.registry, pid)
        state = %{state | registry: registry}
        await_child_termination(state, other, reason)
    after
      wait_time(process.data.shutdown, reason, start_time) ->
        # Brutally kill the child that refuses to stop, and then
        # continue killing the remaining children as normal

        state
        |> await_child_termination([{pid, process}], :kill)
        |> await_child_termination(other, reason)
    end
  end

  defp wait_time(:infinity, _, _), do: :infinity
  defp wait_time(:brutal_kill, _, _), do: :infinity
  defp wait_time(_, :kill, _), do: :infinity

  defp wait_time(shutdown, _reason, start_time) when is_integer(shutdown),
    do: max(shutdown - (:erlang.monotonic_time(:millisecond) - start_time), 0)

  defp shutdown_reason(:normal), do: :shutdown
  defp shutdown_reason(other), do: other

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
