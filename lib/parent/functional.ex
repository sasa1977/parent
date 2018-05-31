defmodule Parent.Functional do
  @moduledoc false
  alias Parent.Registry
  use Parent.PublicTypes

  @opaque t :: %{registry: Registry.t()}
  @type on_handle_message :: {{:EXIT, pid, name, term}, t} | :error

  @spec initialize() :: t
  def initialize() do
    Process.flag(:trap_exit, true)
    %{registry: Registry.new()}
  end

  @spec entries(t) :: [child]
  def entries(state) do
    state.registry
    |> Registry.entries()
    |> Enum.map(fn {pid, process} -> {process.name, pid, process.data.meta} end)
  end

  @spec size(t) :: non_neg_integer
  def size(state), do: Registry.size(state.registry)

  @spec name(t, pid) :: {:ok, name} | :error
  def name(state, pid), do: Registry.name(state.registry, pid)

  @spec pid(t, name) :: {:ok, pid} | :error
  def pid(state, name), do: Registry.pid(state.registry, name)

  @spec meta(t, name) :: {:ok, child_meta} | :error
  def meta(state, name) do
    with {:ok, pid} <- Registry.pid(state.registry, name),
         {:ok, data} <- Registry.data(state.registry, pid),
         do: {:ok, data.meta}
  end

  @spec update_meta(t, name, (child_meta -> child_meta)) :: {:ok, t} | :error
  def update_meta(state, name, updater) do
    with {:ok, pid} <- Registry.pid(state.registry, name),
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

  @spec shutdown_child(t, name) :: t
  def shutdown_child(state, child_name) do
    case Registry.pid(state.registry, child_name) do
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

        {:ok, _name, _data, registry} = Registry.pop(state.registry, pid)
        %{state | registry: registry}
    end
  end

  @spec handle_message(t, term) :: on_handle_message
  def handle_message(state, {:EXIT, pid, reason}) do
    with {:ok, name, data, registry} <- Registry.pop(state.registry, pid) do
      {{:EXIT, pid, name, data.meta, reason}, %{state | registry: registry}}
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
        {:ok, _name, _data, registry} = Registry.pop(state.registry, pid)
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
