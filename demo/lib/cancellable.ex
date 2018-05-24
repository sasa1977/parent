defmodule Demo.Cancellable do
  use Parent.GenServer

  def start_link(), do: Parent.GenServer.start_link(__MODULE__, nil)

  def stop(pid), do: GenServer.stop(pid)

  @impl GenServer
  def init(_) do
    Parent.GenServer.start_child(%{
      id: :job,
      start: {Task, :start_link, [&job/0]}
    })

    Process.send_after(self(), :timeout, :timer.seconds(1))

    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    IO.puts("timeout")
    {:stop, :timeout, state}
  end

  def handle_info(unknown_message, state), do: super(unknown_message, state)

  @impl Parent.GenServer
  def handle_child_terminated(:job, _meta, _pid, reason, state) do
    if reason == :normal do
      IO.puts("job succeeded")
    else
      IO.puts("job failed")
    end

    {:stop, reason, state}
  end

  defp job() do
    num = :rand.uniform(1500)
    Process.sleep(num)
    if :rand.uniform(5) == 1, do: raise("error")
    IO.puts(num)
  end
end
