defmodule Parent.Registry do
  @moduledoc false
  use Parent.PublicTypes

  @opaque t :: %{name_to_pid: %{name => pid}, processes: %{pid => entries}}
  @type entries :: %{name: name, data: data}
  @type data :: map

  @spec new() :: t
  def new(), do: %{name_to_pid: %{}, processes: %{}}

  @spec entries(t) :: entries
  def entries(registry), do: registry.processes

  @spec size(t) :: non_neg_integer
  def size(registry), do: registry |> entries() |> Enum.count()

  @spec name(t, pid) :: {:ok, name} | :error
  def name(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid), do: {:ok, process.name}
  end

  @spec data(t, pid) :: {:ok, data} | :error
  def data(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid), do: {:ok, process.data}
  end

  @spec pid(t, name) :: {:ok, pid} | :error
  def pid(registry, name), do: Map.fetch(registry.name_to_pid, name)

  @spec register(t, name, pid, data) :: t
  def register(registry, name, pid, data) do
    if match?(%{processes: %{^pid => _}}, registry),
      do: raise("process #{inspect(pid)} is already registered")

    if match?(%{name_to_pid: %{^name => _}}, registry),
      do: raise("name #{inspect(name)} is already taken")

    registry
    |> put_in([:name_to_pid, name], pid)
    |> put_in([:processes, pid], %{name: name, data: data})
  end

  @spec pop(t, pid) :: {:ok, name, data, t} | :error
  def pop(registry, pid) do
    with {:ok, process} <- Map.fetch(registry.processes, pid) do
      {:ok, process.name, process.data,
       registry
       |> update_in([:name_to_pid], &Map.delete(&1, process.name))
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
