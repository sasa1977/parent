defmodule Parent.Functional do
  @moduledoc false
  alias Parent.Registry
  use Parent.PublicTypes

  @opaque t :: %{registry: Registry.t()}
  @type on_handle_message :: {{:EXIT, pid, id, term}, t} | :error | :ignore

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
        timer_ref: timer_ref
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

    # The registry now contains only children which refused to die. These
    # children are already forcefully terminated, so now we just have to
    # wait for the :EXIT message.
    Enum.each(Registry.entries(state.registry), fn {pid, _data} ->
      receive do
        {:EXIT, ^pid, _reason} -> :ok
      end
    end)

    %{state | registry: Registry.new()}
  end

  defp terminate_all_children(state, reason) do
    pids_and_specs =
      state.registry
      |> Registry.entries()
      |> Enum.sort_by(fn {_pid, process} -> process.data.shutdown end)

    # Kill all timeout timers first, because we don't want timeout to interfere with the shutdown logic.
    Enum.each(pids_and_specs, fn {pid, process} -> kill_timer(process.data.timer_ref, pid) end)

    Enum.each(pids_and_specs, &stop_process(&1, reason))
    await_terminated_children(state, pids_and_specs, :erlang.monotonic_time(:millisecond))
  end

  defp stop_process({pid, %{shutdown: :brutal_kill}}, _), do: Process.exit(pid, :kill)
  defp stop_process({pid, _spec}, reason), do: Process.exit(pid, reason)

  defp await_terminated_children(state, [], _start_time), do: state

  defp await_terminated_children(state, [{pid, process} | other], start_time) do
    receive do
      {:EXIT, ^pid, _reason} ->
        {:ok, _id, _data, registry} = Registry.pop(state.registry, pid)
        state = %{state | registry: registry}
        await_terminated_children(state, other, start_time)
    after
      wait_time(process.data.shutdown, start_time) ->
        # Brutally killing the child which refuses to stop, but we won't wait
        # for the exit signal now. We'll focus on other children first, and
        # then wait for the ones we had to forcefully kill in the next pass.

        Process.exit(pid, :kill)
        await_terminated_children(state, other, start_time)
    end
  end

  defp wait_time(:infinity, _), do: :infinity
  defp wait_time(:brutal_kill, _), do: :infinity

  defp wait_time(shutdown, start_time) when is_integer(shutdown),
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
