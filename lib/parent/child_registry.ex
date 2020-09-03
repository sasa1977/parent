defmodule Parent.ChildRegistry do
  @moduledoc false
  alias Parent.MetaRegistry

  @spec whereis(GenServer.server(), Parent.child_id()) :: pid | nil
  def whereis(parent, child_id) do
    with parent_pid when not is_nil(parent_pid) <- GenServer.whereis(parent),
         {:ok, table} <- MetaRegistry.table(parent_pid),
         [[pid]] <- :ets.match(table, {{parent_pid, child_id}, :"$1"}) do
      pid
    else
      _ -> nil
    end
  end

  @doc false
  @spec register(pid, Parent.child_spec()) :: :ok
  def register(child_pid, child_spec) do
    table = ensure_table()
    key = {self(), child_spec.id}
    objects = [{child_pid, key}, {key, child_pid}]
    :ets.insert(table, objects)
    :ok
  end

  @doc false
  @spec unregister(pid) :: :ok
  def unregister(child_pid) do
    table = MetaRegistry.table!(self())
    [[key]] = :ets.match(table, {child_pid, :"$1"})
    :ets.delete(table, key)
    :ets.delete(table, child_pid)
    :ok
  end

  defp ensure_table do
    case MetaRegistry.table(self()) do
      {:ok, table} ->
        table

      :error ->
        table =
          :ets.new(__MODULE__, [
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        MetaRegistry.register_table!(table)
        table
    end
  end
end
