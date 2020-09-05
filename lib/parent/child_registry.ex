defmodule Parent.ChildRegistry do
  @moduledoc false
  alias Parent.MetaRegistry

  def initialize do
    MetaRegistry.register_table!(
      :ets.new(__MODULE__, [
        :public,
        :duplicate_bag,
        read_concurrency: true,
        write_concurrency: true
      ])
    )
  end

  @spec whereis_child(GenServer.server(), Parent.child_id()) :: pid | nil
  def whereis_child(parent, child_id) do
    with parent_pid when not is_nil(parent_pid) <- GenServer.whereis(parent),
         {:ok, table} <- MetaRegistry.table(parent_pid),
         [[pid]] <- :ets.match(table, {{:id, child_id}, :"$1"}) do
      pid
    else
      _ -> nil
    end
  end

  @spec children_in_role(GenServer.server(), Parent.child_role()) :: [pid]
  def children_in_role(parent, child_role) do
    with parent_pid when not is_nil(parent_pid) <- GenServer.whereis(parent),
         {:ok, table} <- MetaRegistry.table(parent_pid),
         rows <- :ets.match(table, {{:role, child_role}, :"$1"}) do
      List.flatten(rows)
    else
      _ -> []
    end
  end

  @spec register(pid, Parent.child_spec()) :: :ok
  def register(child_pid, child_spec) do
    {:ok, table} = MetaRegistry.table(self())

    :ets.insert(
      table,
      [
        {child_pid, child_spec.id, child_spec.roles},
        {{:id, child_spec.id}, child_pid}
        | Enum.map(child_spec.roles, &{{:role, &1}, child_pid})
      ]
    )

    :ok
  end

  @doc false
  @spec unregister(pid) :: :ok
  def unregister(child_pid) do
    table = MetaRegistry.table!(self())

    with [[child_id, child_roles]] <- :ets.match(table, {child_pid, :"$1", :"$2"}) do
      :ets.delete(table, {:id, child_id})
      Enum.each(child_roles, &:ets.delete(table, {:role, &1}))
      :ets.delete(table, child_pid)
    end

    :ok
  end
end
