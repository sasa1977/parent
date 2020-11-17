defmodule Parent.Restart do
  @moduledoc false
  alias Parent.State

  # core logic of all restarts, both automatic and manual
  def perform(state, children, opts \\ []) do
    # Reject already started children (idempotence)
    to_start = Enum.reject(children, &State.child?(state, &1.spec.id))

    {to_start, state} =
      if Keyword.get(opts, :restart?, true),
        do: record_restart(state, to_start),
        else: {to_start, state}

    # First we'll return all entries to the parent without starting the processes. This will
    # simplify handling a failed start of some child.
    {children, state} = return_children_entries(state, to_start)

    # Now we can proceed to restart the children if needed
    if Keyword.get(opts, :restart?, true) do
      {not_started, state} = restart_children(state, children)
      Enum.reduce(not_started, state, &handle_not_started(&2, &1))
    else
      state
    end
  end

  defp record_restart(state, children) do
    Enum.flat_map_reduce(
      children,
      state,
      fn
        %{record_restart?: true} = child, state ->
          {child, state} = record_restart!(state, child)
          {[child], state}

        child, state ->
          {[child], state}
      end
    )
  end

  defp record_restart!(state, child) do
    with {:ok, state} <- State.record_restart(state),
         {:ok, restart_counter} <- Parent.RestartCounter.record_restart(child.restart_counter) do
      {%{child | restart_counter: restart_counter}, state}
    else
      _ ->
        Parent.give_up!(state, :too_many_restarts, "Too many restarts in parent process.")
    end
  end

  defp return_children_entries(state, children) do
    {state, _keys, children} =
      children
      |> Enum.sort_by(& &1.startup_index)
      |> Enum.reduce(
        {state, %{}, []},
        fn child, {state, keys, children} ->
          # if a child binds to a sibling via a pid we need to update the bindings to the correct key
          child =
            update_in(child.spec.binds_to, fn binds_to ->
              Enum.map(binds_to, &Map.get(keys, &1, &1))
            end)

          {key, state} =
            State.reregister_child(
              state,
              child |> Map.delete(:exit_reason) |> Map.delete(:record_restart?),
              :undefined,
              nil
            )

          keys = Map.put(keys, child.key, key)
          child = Map.merge(child, State.child!(state, key))
          {state, keys, [child | children]}
        end
      )

    {Enum.reverse(children), state}
  end

  defp restart_children(state, children) do
    {stopped, state} =
      Enum.reduce(
        children,
        {[], state},
        fn child, {stopped, state} ->
          {new_stopped, state} =
            if State.child?(state, child.key),
              do: restart_child(state, child),
              # A child might not be in a state if it was removed because its dependency failed to start
              else: {[], state}

          {new_stopped ++ stopped, state}
        end
      )

    {Enum.reverse(stopped), state}
  end

  defp restart_child(state, child) do
    case Parent.start_validated_child(state, child.spec) do
      {:ok, pid, timer_ref} ->
        {[], State.set_child_process(state, child.key, pid, timer_ref)}

      {:error, start_error} ->
        {:ok, children, state} = State.pop_child_with_bound_siblings(state, child.key)
        Parent.stop_children(children, :shutdown)
        {[{child.key, start_error, children}], state}
    end
  end

  defp handle_not_started(state, {key, error, children}) do
    {[failed_child], bound_siblings} = Enum.split_with(children, &(&1.key == key))
    failed_child = Map.merge(failed_child, %{exit_reason: error, record_restart?: true})

    cond do
      failed_child.spec.restart != :temporary ->
        # Failed start of a non-temporary -> auto restart
        {children, state} = return_children_entries(state, [failed_child | bound_siblings])
        Parent.enqueue_resume_restart(children)
        state

      failed_child.spec.ephemeral? ->
        # Failed start of a temporary ephemeral child -> notify the client about stopped children
        Parent.notify_stopped_children([failed_child | bound_siblings])
        state

      true ->
        # Failed start of a temporary non-ephemeral child

        {ephemeral, non_ephemeral} =
          Enum.split_with([failed_child | bound_siblings], & &1.spec.ephemeral?)

        # non-ephemeral processes in the group are kept with their pid set to `:undefined`
        {_children, state} = return_children_entries(state, non_ephemeral)

        # notify the client about stopped ephemeral children
        Parent.notify_stopped_children(ephemeral)
        state
    end
  end
end
