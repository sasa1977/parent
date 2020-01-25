defmodule Periodic.TestHelper do
  import Periodic.Test
  import ExUnit.Assertions

  def start_scheduler!(opts \\ []) do
    job_opts = Keyword.take(opts, [:trap_exit?])

    defaults = [
      id: :test_job,
      telemetry_id: :test_job,
      every: 1,
      mode: :manual,
      run: instrumented_job(job_opts)
    ]

    ExUnit.Callbacks.start_supervised!({Periodic, Keyword.merge(defaults, opts)})
  end

  def start_job!(opts \\ []) do
    scheduler = start_scheduler!(opts)
    tick(scheduler)
    assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler, job: job})
    {scheduler, job}
  end

  def finish_job(job) do
    mref = Process.monitor(job)
    send(job, :finish)
    assert_receive {:DOWN, ^mref, :process, ^job, _}, 100
    :ok
  end

  defp instrumented_job(job_opts) do
    test_pid = self()

    fn ->
      Process.flag(:trap_exit, Keyword.get(job_opts, :trap_exit?, false))
      send(test_pid, {:started, self()})

      receive do
        :finish -> :ok
        {:crash, reason} -> exit(reason)
      end
    end
  end
end
