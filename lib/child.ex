defmodule Child do
  alias Parent.ChildRegistry

  @doc """
  Returns the pid of the child of the given parent, or nil if such child or parent doesn't exist.

  This function only works if the parent process is initialized with the `registry?: true` option.
  """
  @spec pid(GenServer.server(), Parent.child_id()) :: pid | nil
  defdelegate pid(parent, child_id), to: ChildRegistry, as: :child_pid

  @doc """
  Returns all the pids of the children of the given parent who are in the given role.

  This function only works if the parent process is initialized with the `registry?: true` option.
  """
  @spec pids(GenServer.server(), Parent.child_role()) :: [pid]
  defdelegate pids(parent, child_role), to: ChildRegistry, as: :child_pids

  @doc false
  def whereis_name({parent, child_id}) do
    with nil <- pid(parent, child_id), do: :undefined
  end
end
