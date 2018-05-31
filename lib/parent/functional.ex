defmodule Parent.Functional do
  @moduledoc false
  alias Parent.Registry
  use Parent.PublicTypes

  @opaque t :: %{registry: Registry.t()}
  @type on_handle_message :: {{:EXIT, pid, id, term}, t} | :error

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
      data = %{shutdown: full_child_spec.shutdown, meta: full_child_spec.meta}
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

        {:ok, _id, _data, registry} = Registry.pop(state.registry, pid)
        %{state | registry: registry}
    end
  end

  @spec handle_message(t, term) :: on_handle_message
  def handle_message(state, {:EXIT, pid, reason}) do
    with {:ok, id, data, registry} <- Registry.pop(state.registry, pid) do
      {{:EXIT, pid, id, data.meta, reason}, %{state | registry: registry}}
    end
  end

  def handle_message(_state, _other), do: :error

  @spec shutdown_all(t, term) :: t
  def shutdown_all(state, reason) do
    state = terminate_all_children(state, shutdown_reason(reason))

    Enum.each(Registry.entries(state.registry), fn {pid, _data} ->
      await_child_termination(pid)
    end)

    %{state | registry: Registry.new()}
  end

  defp terminate_all_children(state, reason) do
    pids_and_specs =
      state.registry
      |> Registry.entries()
      |> Enum.sort_by(fn {_pid, process} -> process.data.shutdown end)

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
        Process.exit(pid, :kill)
        await_terminated_children(state, other, 0)
    end
  end

  defp wait_time(:infinity, _), do: :infinity
  defp wait_time(:brutal_kill, _), do: :infinity

  defp wait_time(shutdown, start_time) when is_integer(shutdown),
    do: max(shutdown - (:erlang.monotonic_time(:millisecond) - start_time), 0)

  defp shutdown_reason(:normal), do: :shutdown
  defp shutdown_reason(other), do: other

  defp await_child_termination(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    end
  end

  @default_spec %{shutdown: :timer.seconds(5), meta: nil}

  defp expand_child_spec(mod) when is_atom(mod), do: expand_child_spec({mod, nil})
  defp expand_child_spec({mod, arg}), do: expand_child_spec(mod.child_spec(arg))
  defp expand_child_spec(%{} = child_spec), do: Map.merge(@default_spec, child_spec)
  defp expand_child_spec(_other), do: raise("invalid child_spec")

  defp start_child_process({mod, fun, args}), do: apply(mod, fun, args)
  defp start_child_process(fun) when is_function(fun, 0), do: fun.()
end
