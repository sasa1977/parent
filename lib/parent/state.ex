defmodule Parent.State do
  @moduledoc false

  alias Parent.RestartCounter

  @opaque t :: %{
            opts: Parent.opts(),
            id_to_key: %{Parent.child_id() => key},
            children: %{key => child()},
            startup_index: non_neg_integer,
            restart_counter: RestartCounter.t(),
            registry?: boolean,
            bound: %{key => [key]},
            shutdown_groups: %{Parent.shutdown_group() => [key]}
          }

  @opaque key :: pid | {__MODULE__, reference()}

  @type child :: %{
          spec: Parent.child_spec(),
          pid: pid,
          timer_ref: reference() | nil,
          startup_index: non_neg_integer(),
          restart_counter: RestartCounter.t(),
          meta: Parent.child_meta(),
          key: key
        }

  @spec initialize(Parent.opts()) :: t
  def initialize(opts) do
    opts = Keyword.merge([max_restarts: 3, max_seconds: 5, registry?: false], opts)

    %{
      opts: opts,
      id_to_key: %{},
      children: %{},
      startup_index: 0,
      restart_counter: RestartCounter.new(opts[:max_restarts], opts[:max_seconds]),
      registry?: Keyword.fetch!(opts, :registry?),
      bound: %{},
      shutdown_groups: %{}
    }
  end

  @spec reinitialize(t) :: t
  def reinitialize(state), do: %{initialize(state.opts) | startup_index: state.startup_index}

  @spec registry?(t) :: boolean
  def registry?(state), do: state.registry?

  @spec register_child(t, pid, Parent.child_spec(), reference | nil) :: t
  def register_child(state, pid, spec, timer_ref) do
    key = child_key(pid)

    false = Map.has_key?(state.children, pid)

    child = %{
      spec: spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: state.startup_index,
      restart_counter: RestartCounter.new(spec.max_restarts, spec.max_seconds),
      meta: spec.meta,
      key: key
    }

    state =
      if is_nil(spec.id),
        do: state,
        else: Map.update!(state, :id_to_key, &Map.put(&1, spec.id, key))

    state
    |> Map.update!(:children, &Map.put(&1, key, child))
    |> Map.update!(:startup_index, &(&1 + 1))
    |> update_bindings(key, spec)
    |> update_shutdown_groups(key, spec)
  end

  @spec register_child(t, pid, child, reference | nil) :: t
  def reregister_child(state, child, pid, timer_ref) do
    key = child_key(pid)

    false = Map.has_key?(state.children, pid)

    child = %{child | pid: pid, timer_ref: timer_ref, meta: child.spec.meta, key: key}

    state =
      if is_nil(child.spec.id),
        do: state,
        else: Map.update!(state, :id_to_key, &Map.put(&1, child.spec.id, key))

    state
    |> Map.update!(:children, &Map.put(&1, child.key, child))
    |> update_bindings(key, child.spec)
    |> update_shutdown_groups(key, child.spec)
  end

  @spec children(t) :: [child()]
  def children(state), do: Map.values(state.children)

  @spec children_in_shutdown_group(t, Parent.shutdown_group()) :: [child]
  def children_in_shutdown_group(state, shutdown_group),
    do: Map.get(state.shutdown_groups, shutdown_group, []) |> Enum.map(&child!(state, &1))

  @spec record_restart(t) :: {:ok, t} | :error
  def record_restart(state) do
    with {:ok, counter} <- RestartCounter.record_restart(state.restart_counter),
         do: {:ok, %{state | restart_counter: counter}}
  end

  @spec pop_child_with_bound_siblings(t, Parent.child_ref()) :: {:ok, [child], t} | :error
  def pop_child_with_bound_siblings(state, child_ref) do
    with {:ok, child} <- child(state, child_ref) do
      {children, state} = pop_child_and_bound_children(state, child.key)
      {:ok, children, state}
    end
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

  @spec child(t, Parent.child_ref()) :: {:ok, child} | :error
  def child(_state, nil), do: :error
  def child(state, {__MODULE__, _ref} = key), do: Map.fetch(state.children, key)
  def child(state, pid) when is_pid(pid), do: Map.fetch(state.children, pid)

  def child(state, id),
    do: with({:ok, key} <- Map.fetch(state.id_to_key, id), do: child(state, key))

  @spec child?(t, Parent.child_ref()) :: boolean()
  def child?(state, child_ref), do: match?({:ok, _child}, child(state, child_ref))

  @spec child!(t, Parent.child_ref()) :: child
  def child!(state, child_ref) do
    {:ok, child} = child(state, child_ref)
    child
  end

  @spec child_id(t, pid) :: {:ok, Parent.child_id()} | :error
  def child_id(state, pid) do
    with {:ok, child} <- child(state, pid), do: {:ok, child.spec.id}
  end

  @spec child_pid(t, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(state, id), do: with({:ok, child} <- child(state, id), do: {:ok, child.pid})

  @spec child_meta(t, Parent.child_ref()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(state, child_ref) do
    with {:ok, child} <- child(state, child_ref), do: {:ok, child.meta}
  end

  @spec update_child_meta(t, Parent.child_ref(), (Parent.child_meta() -> Parent.child_meta())) ::
          {:ok, Parent.child_meta(), t} | :error
  def update_child_meta(state, child_ref, updater) do
    with {:ok, child, state} <- update(state, child_ref, &update_in(&1.meta, updater)),
         do: {:ok, child.meta, state}
  end

  defp child_key(:undefined), do: {__MODULE__, make_ref()}
  defp child_key(pid) when is_pid(pid), do: pid

  defp update_bindings(state, key, child_spec) do
    Enum.reduce(
      child_spec.binds_to,
      state,
      fn child_ref, state ->
        bound = child!(state, child_ref)
        %{state | bound: Map.update(state.bound, bound.key, [key], &[key | &1])}
      end
    )
  end

  defp update_shutdown_groups(state, _key, %{shutdown_group: nil}), do: state

  defp update_shutdown_groups(state, key, spec) do
    Map.update!(
      state,
      :shutdown_groups,
      &Map.update(&1, spec.shutdown_group, [key], fn keys -> [key | keys] end)
    )
  end

  defp update(state, child_ref, updater) do
    with {:ok, child} <- child(state, child_ref),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, child.key, updated_child),
         do: {:ok, updated_child, %{state | children: updated_children}}
  end

  defp pop_child_and_bound_children(state, child_ref) do
    child = child!(state, child_ref)
    children = child_with_bound_siblings(state, child)
    state = Enum.reduce(children, state, &remove_child(&2, &1))
    {children, state}
  end

  defp child_with_bound_siblings(state, child),
    do: Map.values(child_with_bound_siblings(state, child, %{}))

  defp child_with_bound_siblings(state, child, collected) do
    # collect all siblings in the same shutdown group
    group_children =
      if is_nil(child.spec.shutdown_group),
        do: [child],
        else: children_in_shutdown_group(state, child.spec.shutdown_group)

    collected = Enum.reduce(group_children, collected, &Map.put_new(&2, &1.key, &1))

    for child <- group_children,
        bound_pid <- Map.get(state.bound, child.key, []),
        bound_sibling = child!(state, bound_pid),
        sibling_key = bound_sibling.key,
        not Map.has_key?(collected, bound_sibling.key),
        reduce: collected do
      %{^sibling_key => _} = collected ->
        collected

      collected ->
        child_with_bound_siblings(
          state,
          bound_sibling,
          Map.put(collected, bound_sibling.key, bound_sibling)
        )
    end
  end

  defp remove_child(state, child) do
    group = child.spec.shutdown_group

    state
    |> Map.update!(:id_to_key, &Map.delete(&1, child.spec.id))
    |> Map.update!(:children, &Map.delete(&1, child.key))
    |> Map.update!(:bound, &Map.delete(&1, child.key))
    |> remove_child_from_bound(child)
    |> Map.update!(:shutdown_groups, fn
      groups ->
        with %{^group => children} <- groups do
          case children -- [child.key] do
            [] -> Map.delete(groups, group)
            children -> %{groups | group => children}
          end
        end
    end)
  end

  defp remove_child_from_bound(state, child) do
    Enum.reduce(
      child.spec.binds_to,
      state,
      fn dep, state ->
        case child(state, dep) do
          {:ok, dep_child} -> update_in(state.bound[dep_child.key], &(&1 -- [child.key]))
          :error -> state
        end
      end
    )
  end
end
