defmodule Parent.Restart do
  @moduledoc false
  alias Parent.State

  # core logic of all restarts, both automatic and manual
  def perform(state, children, opts \\ []) do
    to_start =
      children
      # reject already started children (idempotence)
      |> Stream.reject(&State.child?(state, &1.spec.id))
      |> Enum.sort_by(& &1.startup_index)

    {to_start, state} =
      if Keyword.get(opts, :restart?, true),
        do: record_restart(state, to_start),
        else: {to_start, state}

    {not_started, state, start_error} = return_children(state, to_start, opts)

    if not_started == [],
      do: state,
      else: handle_not_started_children(state, not_started, start_error)
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

  defp return_children(state, children, opts, new_pids \\ %{})

  defp return_children(state, [], _opts, _new_pids), do: {[], state, nil}

  defp return_children(state, [child | children], opts, new_pids) do
    child = update_bindings(child, new_pids)

    start_result =
      if Keyword.get(opts, :restart?, true),
        do: Parent.start_child_process(state, child.spec),
        else: {:ok, :undefined, nil}

    case start_result do
      {:ok, new_pid, timer_ref} ->
        {key, state} = State.reregister_child(state, child, new_pid, timer_ref)
        return_children(state, children, opts, Map.put(new_pids, child.key, key))

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

  defp handle_not_started_children(state, not_started, start_error) do
    # stop successfully started children which are bound to non-started ones
    {extra_stopped_children, state} =
      stop_children_in_shutdown_groups(state, shutdown_groups(not_started))

    failed_child = Map.merge(hd(not_started), %{exit_reason: start_error, record_restart?: true})

    other_children =
      [tl(not_started), extra_stopped_children]
      |> Stream.concat()
      |> Enum.map(&Map.put(&1, :exit_reason, :shutdown))

    children_to_restart =
      if failed_child.spec.restart == :temporary,
        do: handle_start_error(failed_child, other_children),
        else: [failed_child | other_children]

    Parent.enqueue_resume_restart(children_to_restart)

    state
  end

  defp handle_start_error(failed_child, other_children) do
    {failed_children, children_to_restart} =
      Enum.reduce(
        other_children,
        {[failed_child], []},
        fn child, {failed_children, children_to_restart} ->
          if Enum.any?(failed_children, &bound_to?(child, &1)) do
            # we need to recheck children we already processed to see if any of them is bound to
            # this child
            {extra_failed_children, children_to_restart} =
              Enum.split_with(children_to_restart, &bound_to?(&1, child))

            {[child | extra_failed_children ++ failed_children], children_to_restart}
          else
            {failed_children, [child | children_to_restart]}
          end
        end
      )

    Parent.notify_stopped_children(Enum.reverse(failed_children))
    children_to_restart
  end

  defp bound_to?(child1, child2) do
    (not is_nil(child1.spec.shutdown_group) and
       child1.spec.shutdown_group == child2.spec.shutdown_group) or
      Enum.any?(child1.spec.binds_to, &(&1 in [child2.spec.id, child2.pid]))
  end
end
