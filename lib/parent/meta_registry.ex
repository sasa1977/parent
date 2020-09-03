defmodule Parent.MetaRegistry do
  @moduledoc false

  def register_table!(table) do
    {:ok, _} = Registry.register(__MODULE__, self(), table)
    :ok
  end

  def table(parent_pid) do
    case Registry.lookup(__MODULE__, parent_pid) do
      [{^parent_pid, table}] -> {:ok, table}
      [] -> :error
    end
  end

  def table!(parent_pid) do
    {:ok, table} = table(parent_pid)
    table
  end

  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)
end
