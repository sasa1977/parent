defmodule Demo.Periodic do
  use Parent.GenServer

  def start_link(), do: Parent.GenServer.start_link(__MODULE__, nil)

  @impl GenServer
  def init(_) do
    :timer.send_interval(:timer.seconds(1), :run_job)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:run_job, state) do
    if Parent.GenServer.child?(:job) do
      IO.puts("previous job already running")
    else
      Parent.GenServer.start_child(%{
        id: :job,
        start: {Task, :start_link, [&job/0]}
      })
    end

    {:noreply, state}
  end

  def handle_info(unknown_message, state), do: super(unknown_message, state)

  defp job() do
    num = :rand.uniform(2000)
    Process.sleep(num)
    IO.puts(num)
  end
end
