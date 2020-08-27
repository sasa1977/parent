defmodule Demo.Queue do
  use Parent.GenServer

  def start_link() do
    Parent.GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def add_jobs(count) do
    GenServer.call(__MODULE__, {:add_jobs, count})
  end

  @impl GenServer
  def init(_) do
    {:ok, %{pending: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:add_jobs, count}, _from, state) do
    state = Enum.reduce(1..count, state, &push_item(&2, &1))
    {:reply, :ok, state}
  end

  @impl Parent.GenServer
  def handle_child_terminated(_id, _meta, _pid, reason, state) do
    if reason == :normal do
      IO.puts("job succeeded")
    else
      IO.puts("job failed")
    end

    {:noreply, maybe_start_next_job(state)}
  end

  defp push_item(state, item) do
    state.pending
    |> update_in(&:queue.in(item, &1))
    |> maybe_start_next_job()
  end

  defp maybe_start_next_job(state) do
    with max_jobs = 10,
         true <- Parent.num_children() < max_jobs,
         {{:value, _item}, remaining} <- :queue.out(state.pending) do
      start_job()
      maybe_start_next_job(%{state | pending: remaining})
    else
      _ -> state
    end
  end

  defp start_job() do
    Parent.start_child(%{
      id: make_ref(),
      start: {Task, :start_link, [&job/0]}
    })
  end

  defp job() do
    num = :rand.uniform(1500)
    Process.sleep(num)
    if :rand.uniform(5) == 1, do: raise("error")
  end
end
