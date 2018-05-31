# Parent

[![hex.pm](https://img.shields.io/hexpm/v/parent.svg?style=flat-square)](https://hex.pm/packages/parent)
[![hexdocs.pm](https://img.shields.io/badge/docs-latest-green.svg?style=flat-square)](https://hexdocs.pm/parent/)

Support for custom parenting of processes. See [rationale](./RATIONALE.md) for detailed explanation, and [docs](https://hexdocs.pm/parent/) for reference.

## Example

The following example implements a parent GenServer which starts a child task, and handles its termination by starting another task after one second.

```elixir
defmodule MyParent do
  use Parent.GenServer
  require Logger

  def start_link(_), do: Parent.GenServer.start_link(__MODULE__, nil)

  @impl GenServer
  def init(_arg) do
    start_job(1)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:start_job, job_number}, state) do
    start_job(job_number)
    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  @impl Parent.GenServer
  def handle_child_terminated(:job, job_number, _pid, _reason, state) do
    Logger.info("job #{job_number} finished")
    Process.send_after(self(), {:start_job, job_number + 1}, :timer.seconds(1))
    {:noreply, state}
  end

  defp start_job(job_number) do
    Logger.info("starting job #{job_number}")

    Parent.GenServer.start_child(%{
      id: :job,
      start: {Task, :start_link, [&run_job/0]},
      meta: job_number
    })
  end

  defp run_job() do
    Logger.info("processing ...")

    # simulates random job duration
    Process.sleep(:rand.uniform(5000))
  end
end

iex> Supervisor.start_link([MyParent], strategy: :one_for_one)

09:26:28.153 [info] starting job 1
09:26:28.156 [info] processing ...
09:26:32.655 [info] job 1 finished

09:26:33.656 [info] starting job 2
09:26:33.656 [info] processing ...
09:26:37.043 [info] job 2 finished

09:26:38.044 [info] starting job 3
09:26:38.044 [info] processing ...
09:26:40.702 [info] job 3 finished
...
```

## Status

This library is still in its very early days. It is being used in the production code, but not extensively.

## License

[MIT](./LICENSE)
