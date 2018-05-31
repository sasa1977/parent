defmodule Parent.Registry do
  @moduledoc false
  use Parent.PublicTypes

  @opaque t :: %{id_to_pid: %{id => pid}, processes: entries}
  @type entries :: %{pid => %{id: id, data: data}}
  @type data :: map

  @spec new() :: t
  def new(), do: %{id_to_pid: %{}, processes: %{}}

  @spec entries(t) :: entries
  def entries(registry), do: registry.processes

  @spec size(t) :: non_neg_integer
  def size(registry), do: registry |> entries() |> Enum.count()

  @spec id(t, pid) :: {:ok, id} | :error
  def id(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid), do: {:ok, process.id}
  end

  @spec data(t, pid) :: {:ok, data} | :error
  def data(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid), do: {:ok, process.data}
  end

  @spec pid(t, id) :: {:ok, pid} | :error
  def pid(registry, id), do: Map.fetch(registry.id_to_pid, id)

  @spec register(t, id, pid, data) :: t
  def register(registry, id, pid, data) do
    if match?(%{processes: %{^pid => _}}, registry),
      do: raise("process #{inspect(pid)} is already registered")

    if match?(%{id_to_pid: %{^id => _}}, registry),
      do: raise("id #{inspect(id)} is already taken")

    registry
    |> put_in([:id_to_pid, id], pid)
    |> put_in([:processes, pid], %{id: id, data: data})
  end

  @spec pop(t, pid) :: {:ok, id, data, t} | :error
  def pop(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid) do
      {:ok, process.id, process.data,
       registry
       |> update_in([:id_to_pid], &Map.delete(&1, process.id))
       |> update_in([:processes], &Map.delete(&1, pid))}
    end
  end

  @spec update(t, pid, (data -> data)) :: {:ok, t} | :error
  def update(registry, pid, updater) do
    with {:ok, process} <- Map.fetch(registry.processes, pid),
         updated_data = updater.(process.data),
         updated_process = %{process | data: updated_data},
         updated_processes = Map.put(registry.processes, pid, updated_process),
         do: {:ok, %{registry | processes: updated_processes}}
  end
end
