defmodule Parent.Registry do
  @moduledoc false
  alias Parent.MetaRegistry

  @opaque table :: :ets.tid()

  @spec initialize :: :ok
  def initialize do
    MetaRegistry.register_table!(
      :ets.new(__MODULE__, [
        :protected,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    )
  end

  @spec table(pid) :: {:ok, table} | :error
  def table(parent), do: MetaRegistry.table(GenServer.whereis(parent))

  @spec register(pid, Parent.child_spec()) :: :ok
  def register(child_pid, child_spec) do
    table = MetaRegistry.table!(self())
    key = {:id, child_spec.id}
    :ets.insert(table, [{child_pid, key}, {key, child_pid, child_spec.meta}])
    :ok
  end

  @spec unregister(pid) :: :ok
  def unregister(child_pid) do
    table = MetaRegistry.table!(self())

    with [[key]] <- :ets.match(table, {child_pid, :"$1"}),
         do: :ets.delete(table, key)

    :ets.delete(table, child_pid)
    :ok
  end

  @spec update_meta(Parent.child_id(), Parent.child_meta()) :: :ok
  def update_meta(child_id, meta) do
    table = MetaRegistry.table!(self())
    true = :ets.update_element(table, {:id, child_id}, {3, meta})
    :ok
  end

  @spec children(table) :: [Parent.child()]
  def children(table) do
    table
    |> :ets.match({{:id, :"$1"}, :"$2", :"$3"})
    |> Enum.map(fn [id, pid, meta] -> %{id: id, meta: meta, pid: pid} end)
  end

  @spec child_pid(table, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(table, child_id) do
    case :ets.match(table, {{:id, child_id}, :"$1", :_}) do
      [[pid]] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec child_meta(table, Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(table, child_id) do
    case :ets.match(table, {{:id, child_id}, :_, :"$1"}) do
      [[meta]] -> {:ok, meta}
      [] -> :error
    end
  end
end
