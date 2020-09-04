defmodule Parent.State do
  @moduledoc false

  alias Parent.RestartCounter

  @opaque t :: %{
            opts: Parent.opts(),
            id_to_pid: %{Parent.child_id() => pid},
            children: %{pid => child()},
            startup_index: non_neg_integer,
            restart_counter: RestartCounter.t()
          }

  @type child :: %{
          spec: Parent.child_spec(),
          pid: pid,
          timer_ref: reference() | nil,
          startup_index: non_neg_integer(),
          dependencies: MapSet.t(Parent.child_id()),
          bound_siblings: MapSet.t(Parent.child_id()),
          restart_counter: RestartCounter.t()
        }

  @type filter :: [{:id, Parent.child_id()}] | [{:pid, pid}]

  @spec initialize(Parent.opts()) :: t
  def initialize(opts) do
    opts = Keyword.merge([max_restarts: 3, max_seconds: 5], opts)

    %{
      opts: opts,
      id_to_pid: %{},
      children: %{},
      startup_index: 0,
      restart_counter: RestartCounter.new(opts)
    }
  end

  @spec reinitialize(t) :: t
  def reinitialize(state), do: initialize(state.opts)

  @spec register_child(t, pid, Parent.child_spec(), reference | nil) :: t
  def register_child(state, pid, spec, timer_ref) do
    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, spec.id)

    {dependencies, state} = update_dependencies(state, spec)

    child = %{
      spec: spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: state.startup_index,
      dependencies: dependencies,
      bound_siblings: MapSet.new(),
      restart_counter: RestartCounter.new(spec.restart)
    }

    state
    |> put_in([:id_to_pid, spec.id], pid)
    |> put_in([:children, pid], child)
    |> update_in([:startup_index], &(&1 + 1))
  end

  @spec register_child(t, pid, child, reference | nil) :: t
  def reregister_child(state, child, pid, timer_ref) do
    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, child.spec.id)

    {dependencies, state} = update_dependencies(state, child.spec)

    child = %{
      child
      | pid: pid,
        timer_ref: timer_ref,
        dependencies: dependencies,
        bound_siblings: MapSet.new()
    }

    state
    |> put_in([:id_to_pid, child.spec.id], child.pid)
    |> put_in([:children, child.pid], child)
  end

  @spec children(t) :: [child()]
  def children(state) do
    state.children
    |> Map.values()
    |> Enum.sort_by(& &1.startup_index)
  end

  @spec record_restart(t) :: {:ok, t} | :error
  def record_restart(state) do
    with {:ok, counter} <- RestartCounter.record_restart(state.restart_counter),
         do: {:ok, %{state | restart_counter: counter}}
  end

  @spec pop_child_with_bound_siblings(t, filter) :: {:ok, [child], t} | :error
  def pop_child_with_bound_siblings(state, filter) do
    with {:ok, child} <- child(state, filter) do
      {children, state} =
        List.foldr(
          [child | bound_siblings(state, child)],
          {[], state},
          fn child, {children, state} ->
            {:ok, _child, state} = pop_child(state, pid: child.pid)
            {[child | children], state}
          end
        )

      {:ok, children, state}
    end
  end

  @spec pop_child(t, filter) :: {:ok, child, t} | :error
  def pop_child(state, filter) do
    with {:ok, child} <- child(state, filter) do
      state =
        Enum.reduce(
          child.dependencies,
          state,
          fn dep_id, state ->
            update!(state, [id: dep_id], fn dep ->
              update_in(dep.bound_siblings, &MapSet.delete(&1, child.spec.id))
            end)
          end
        )
        |> update_in([:id_to_pid], &Map.delete(&1, child.spec.id))
        |> update_in([:children], &Map.delete(&1, child.pid))

      {:ok, child, state}
    end
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

  @spec child(t, filter) :: {:ok, child} | :error
  def child(state, id: id),
    do: with({:ok, pid} <- child_pid(state, id), do: child(state, pid: pid))

  def child(state, pid: pid), do: Map.fetch(state.children, pid)

  @spec child!(t, filter) :: child
  def child!(state, filter) do
    {:ok, child} = child(state, filter)
    child
  end

  @spec child_id(t, pid) :: {:ok, Parent.child_id()} | :error
  def child_id(state, pid) do
    with {:ok, child} <- Map.fetch(state.children, pid), do: {:ok, child.spec.id}
  end

  @spec child_pid(t, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(state, id), do: Map.fetch(state.id_to_pid, id)

  @spec child_meta(t, Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(state, id) do
    with {:ok, pid} <- child_pid(state, id),
         {:ok, child} <- Map.fetch(state.children, pid),
         do: {:ok, child.spec.meta}
  end

  @spec update_child_meta(t, Parent.child_id(), (Parent.child_meta() -> Parent.child_meta())) ::
          {:ok, t} | :error
  def update_child_meta(state, id, updater) do
    update(state, [id: id], &update_in(&1.spec.meta, updater))
  end

  defp update(state, filter, updater) do
    with {:ok, child} <- child(state, filter),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, child.pid, updated_child),
         do: {:ok, %{state | children: updated_children}}
  end

  defp update!(state, filter, updater) do
    {:ok, state} = update(state, filter, updater)
    state
  end

  defp update_dependencies(state, spec) do
    dependencies =
      Enum.reduce(
        spec.binds_to,
        MapSet.new(spec.binds_to),
        &MapSet.union(&2, child!(state, id: &1).dependencies)
      )

    state =
      Enum.reduce(
        dependencies,
        state,
        fn dep_id, state ->
          update!(state, [id: dep_id], fn dep ->
            update_in(dep.bound_siblings, &MapSet.put(&1, spec.id))
          end)
        end
      )

    {dependencies, state}
  end

  defp bound_siblings(state, child) do
    child.bound_siblings
    |> Stream.map(&child!(state, id: &1))
    |> Enum.sort_by(& &1.startup_index)
  end
end
