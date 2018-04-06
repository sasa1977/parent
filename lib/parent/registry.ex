defmodule Parent.Registry do
  def new(), do: %{name_to_pid: %{}, pid_to_name: %{}}

  def entries(registry), do: registry.name_to_pid

  def size(registry), do: registry |> entries() |> Enum.count()

  def name(registry, pid), do: Map.fetch(registry.pid_to_name, pid)

  def pid(registry, name), do: Map.fetch(registry.name_to_pid, name)

  def register(registry, name, pid) do
    if match?(%{pid_to_name: %{^pid => _}}, registry),
      do: raise("process #{inspect(pid)} is already registered")

    if match?(%{name_to_pid: %{^name => _}}, registry),
      do: raise("name #{inspect(name)} is already taken")

    registry
    |> put_in([:name_to_pid, name], pid)
    |> put_in([:pid_to_name, pid], name)
  end

  def pop(registry, pid) do
    with {:ok, name} <- name(registry, pid) do
      {:ok, name,
       registry
       |> update_in([:name_to_pid], &Map.delete(&1, name))
       |> update_in([:pid_to_name], &Map.delete(&1, pid))}
    end
  end
end
