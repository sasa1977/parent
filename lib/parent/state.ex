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
          startup_index: non_neg_integer()
        }

  @spec initialize() :: t
  def initialize(), do: %{id_to_pid: %{}, children: %{}, startup_index: 0}

  @spec register_child(t, pid, Parent.child_spec(), reference | nil) :: t
  def register_child(state, pid, full_child_spec, timer_ref) do
    child = %{
      spec: full_child_spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: state.startup_index
    }

    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, full_child_spec.id)

    state
    |> put_in([:id_to_pid, full_child_spec.id], pid)
    |> put_in([:children, pid], child)
    |> update_in([:startup_index], &(&1 + 1))
  end

  @spec children(t) :: [child()]
  def children(state), do: Map.values(state.children)

  @spec pop(t, pid) :: {:ok, child, t} | :error
  def pop(state, pid) do
    with {:ok, child} <- Map.fetch(state.children, pid) do
      {:ok, child,
       state
       |> update_in([:id_to_pid], &Map.delete(&1, child.spec.id))
       |> update_in([:children], &Map.delete(&1, pid))}
    end
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

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
    with {:ok, pid} <- child_pid(state, id),
         do: update(state, pid, &update_in(&1.spec.meta, updater))
  end

  defp update(state, pid, updater) do
    with {:ok, child} <- Map.fetch(state.children, pid),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, pid, updated_child),
         do: {:ok, %{state | children: updated_children}}
  end
end
