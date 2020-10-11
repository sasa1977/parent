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

  @spec table(GenServer.server()) :: {:ok, table} | :error
  def table(parent), do: MetaRegistry.table(GenServer.whereis(parent))

  @spec register(pid, Parent.child_spec()) :: :ok
  def register(child_pid, child_spec) do
    table = MetaRegistry.table!(self())
    key = {:id, with(nil <- child_spec.id, do: child_pid)}
    main_entry = {key, child_pid, child_spec.meta}
    entries = if is_nil(child_spec.id), do: [main_entry], else: [{child_pid, key}, main_entry]
    :ets.insert(table, entries)
    :ok
  end

  @spec unregister(pid) :: :ok
  def unregister(child_pid) do
    table = MetaRegistry.table!(self())
    :ets.delete(table, key(table, child_pid))
    :ets.delete(table, child_pid)
    :ok
  end

  @spec update_meta(Parent.child_ref(), Parent.child_meta()) :: :ok
  def update_meta(child_ref, meta) do
    table = MetaRegistry.table!(self())
    key = key(table, child_ref)
    true = :ets.update_element(table, key, {3, meta})
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

  @spec child_meta(table, Parent.child_ref()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(table, child_ref) do
    case :ets.match(table, {key(table, child_ref), :_, :"$1"}) do
      [[meta]] -> {:ok, meta}
      [] -> :error
    end
  end

  defp key(table, child_ref) do
    if is_pid(child_ref) do
      case :ets.match(table, {child_ref, :"$1"}) do
        [[key]] -> key
        [] -> {:id, child_ref}
      end
    else
      {:id, child_ref}
    end
  end
end
