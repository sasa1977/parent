defmodule Parent.Client do
  @spec child_pid(GenServer.server(), Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(parent, child_id), do: call(parent, {:child_pid, child_id})

  @spec child_meta(GenServer.server(), Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(parent, child_id), do: call(parent, {:child_meta, child_id})

  @spec start_child(GenServer.server(), Parent.start_spec()) :: Supervisor.on_start_child()
  def start_child(parent, child_spec), do: call(parent, {:start_child, child_spec}, :infinity)

  @spec shutdown_child(GenServer.server(), Parent.child_id()) ::
          {:ok, Parent.on_shutdown_child()} | {:error, :unknown_child}
  def shutdown_child(parent, child_id), do: call(parent, {:shutdown_child, child_id}, :infinity)

  @spec restart_child(GenServer.server(), Parent.child_id()) :: :ok | {:error, :unknown_child}
  def restart_child(parent, child_id), do: call(parent, {:restart_child, child_id})

  @spec shutdown_all(GenServer.server()) :: :ok
  def shutdown_all(server), do: call(server, :shutdown_all)

  @spec return_children(GenServer.server(), Parent.return_info()) :: :ok
  def return_children(parent, return_info), do: call(parent, {:return_children, return_info})

  @spec update_child_meta(
          GenServer.server(),
          Parent.child_id(),
          (Parent.child_meta() -> Parent.child_meta())
        ) :: :ok | :error
  def update_child_meta(parent, child_id, updater),
    do: call(parent, {:update_child_meta, child_id, updater})

  @doc false
  def handle_request({:child_pid, child_id}), do: Parent.child_pid(child_id)
  def handle_request({:child_meta, child_id}), do: Parent.child_meta(child_id)
  def handle_request({:start_child, child_spec}), do: Parent.start_child(child_spec)
  def handle_request(:shutdown_all), do: Parent.shutdown_all()

  def handle_request({:shutdown_child, child_id}) do
    if Parent.child?(child_id),
      do: {:ok, Parent.shutdown_child(child_id)},
      else: {:error, :unknown_child}
  end

  def handle_request({:restart_child, child_id}) do
    if Parent.child?(child_id),
      do: Parent.restart_child(child_id),
      else: {:error, :unknown_child}
  end

  def handle_request({:return_children, return_info}),
    do: Parent.return_children(return_info)

  def handle_request({:update_child_meta, child_id, updater}),
    do: Parent.update_child_meta(child_id, updater)

  def call(server, request, timeout \\ 5000)
      when (is_integer(timeout) and timeout >= 0) or timeout == :infinity do
    request = {__MODULE__, request}

    case GenServer.whereis(server) do
      nil ->
        exit({:noproc, {__MODULE__, :call, [server, request, timeout]}})

      pid when pid == self() ->
        exit({:calling_self, {__MODULE__, :call, [server, request, timeout]}})

      pid ->
        try do
          :gen.call(pid, :"$parent_call", request, timeout)
        catch
          :exit, reason ->
            exit({reason, {__MODULE__, :call, [server, request, timeout]}})
        else
          {:ok, res} -> res
        end
    end
  end
end
