defmodule Parent.Restart do
  alias Parent.State

  # core logic of all restarts, both automatic and manual
  def perform(state, children) do
    to_start =
      children
      # reject already started children (idempotence)
      |> Stream.reject(&State.child?(state, &1.spec.id))
      |> Enum.sort_by(& &1.startup_index)

    {to_start, state} = record_restart(state, to_start)

    {not_started, state, start_error} = return_children(state, to_start)

    if not_started == [],
      do: state,
      else: enqueue_resume_restart(state, not_started, start_error)
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

  defp return_children(state, children, new_pids \\ %{})

  defp return_children(state, [], _new_pids), do: {[], state, nil}

  defp return_children(state, [child | children], new_pids) do
    child = update_bindings(child, new_pids)

    case Parent.start_child_process(state, child.spec) do
      {:ok, new_pid, timer_ref} ->
        state
        |> State.reregister_child(child, new_pid, timer_ref)
        |> return_children(children, Map.put(new_pids, child.pid, new_pid))

      {:error, start_error} ->
        # map remaining bindings
        children = Enum.map(children, &update_bindings(&1, new_pids))
        {[child | children], state, start_error}
    end
  end

  defp update_bindings(child, new_pids) do
    # if a child binds to a sibling via pid we need to update the bindings to reflect new pids
    update_in(
      child.spec.binds_to,
      fn binds_to -> Enum.map(binds_to, &Map.get(new_pids, &1, &1)) end
    )
  end

  defp shutdown_groups(children) do
    for child <- children,
        shutdown_group = child.spec.shutdown_group,
        not is_nil(shutdown_group),
        into: MapSet.new(),
        do: shutdown_group
  end

  defp stop_children_in_shutdown_groups(state, shutdown_groups) do
    {children_to_stop, state} =
      Enum.reduce(
        shutdown_groups,
        {[], state},
        fn group, {stopped, state} ->
          state
          |> State.children()
          |> Enum.find(&(&1.spec.shutdown_group == group))
          |> case do
            nil ->
              {stopped, state}

            child ->
              {:ok, children, state} = State.pop_child_with_bound_siblings(state, child.pid)
              {[children | stopped], state}
          end
        end
      )

    children_to_stop =
      children_to_stop |> List.flatten() |> Enum.sort_by(& &1.startup_index, :desc)

    Parent.stop_children(children_to_stop, :shutdown)
    {children_to_stop, state}
  end

  defp enqueue_resume_restart(state, not_started, start_error) do
    # stop successfully started children which are bound to non-started ones
    {extra_stopped_children, state} =
      stop_children_in_shutdown_groups(state, shutdown_groups(not_started))

    [failed_child | other_children] = not_started

    [other_children, extra_stopped_children]
    |> Stream.concat()
    |> Stream.map(&Map.put(&1, :exit_reason, :shutdown))
    |> Stream.concat([Map.merge(failed_child, %{exit_reason: start_error, record_restart?: true})])
    |> Parent.enqueue_resume_restart()

    state
  end
end
