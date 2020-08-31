defmodule Parent.State do
  @moduledoc false

  @opaque t :: %{
            id_to_pid: %{Parent.child_id() => pid},
            children: %{pid => child()},
            startup_index: non_neg_integer
          }

  @type child :: %{
          spec: Parent.child_spec(),
          pid: pid,
          timer_ref: reference() | nil,
          startup_index: non_neg_integer(),
          dependencies: MapSet.t(Parent.child_id()),
          bound_siblings: MapSet.t(Parent.child_id())
        }

  @type filter :: [{:id, Parent.child_id()}] | [{:pid, pid}]

  @spec initialize() :: t
  def initialize(), do: %{id_to_pid: %{}, children: %{}, startup_index: 0}

  @spec register_child(t, pid, Parent.child_spec(), reference | nil, non_neg_integer() | nil) :: t
  def register_child(state, pid, full_child_spec, timer_ref, startup_index \\ nil) do
    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, full_child_spec.id)

    dependencies =
      Enum.reduce(
        full_child_spec.binds_to,
        MapSet.new(full_child_spec.binds_to),
        &MapSet.union(&2, child!(state, id: &1).dependencies)
      )

    state =
      Enum.reduce(
        dependencies,
        state,
        fn dep_id, state ->
          update!(state, [id: dep_id], fn dep ->
            update_in(dep.bound_siblings, &MapSet.put(&1, full_child_spec.id))
          end)
        end
      )

    child = %{
      spec: full_child_spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: startup_index || state.startup_index,
      dependencies: dependencies,
      bound_siblings: MapSet.new()
    }

    state
    |> put_in([:id_to_pid, full_child_spec.id], pid)
    |> put_in([:children, pid], child)
    |> update_in([:startup_index], &if(is_nil(startup_index), do: &1 + 1, else: &1))
  end

  @spec children(t) :: [child()]
  def children(state) do
    state.children
    |> Map.values()
    |> Enum.sort_by(& &1.startup_index)
  end

  @spec pop(t, filter) :: {:ok, child, t} | :error
  def pop(state, filter) do
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
end
