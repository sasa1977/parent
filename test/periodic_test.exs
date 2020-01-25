defmodule PeriodicTest do
  use ExUnit.Case, async: true
  import Periodic.Test

  setup do
    observe()
  end

  test "auto mode" do
    test_pid = self()
    Periodic.start_link(every: 1, run: fn -> send(test_pid, :started) end)
    assert_receive :started
    assert_receive :started
  end

  test "regular job execution" do
    scheduler = start_scheduler!()

    refute_periodic_event(%{scheduler: ^scheduler, event: :started})
    tick(scheduler)
    assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    assert_receive {:started, ^job}

    refute_periodic_event(%{scheduler: ^scheduler, event: :started})
    tick(scheduler)
    assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    assert_receive {:started, ^job}
  end

  test "finished telemetry event" do
    {scheduler, job} = start_job!()
    finish_job(job)
    assert_periodic_event(%{scheduler: ^scheduler, event: :finished, job: ^job}, %{time: time})
    assert is_integer(time) and time > 0
  end

  describe "on_overlap" do
    test "ignore" do
      {scheduler, job} = start_job!(on_overlap: :ignore)

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :skipped, still_running: ^job})
      refute_periodic_event(%{scheduler: ^scheduler, event: :started})

      finish_job(job)
      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    end

    test "stop_previous" do
      {scheduler, job} = start_job!(on_overlap: :stop_previous)

      mref = Process.monitor(job)

      tick(scheduler)
      assert_receive({:DOWN, ^mref, :process, ^job, :killed})
      assert_periodic_event(%{scheduler: ^scheduler, event: :killed_previous, pid: ^job})
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    end
  end

  test "timeout" do
    {_scheduler, job} = start_job!(timeout: 1)
    mref = Process.monitor(job)
    assert_receive({:DOWN, ^mref, :process, ^job, :killed})
  end

  describe "initial_delay" do
    test "is by default equal to the interval" do
      scheduler = start_scheduler!(every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end

    test "overrides the first tick interval" do
      scheduler = start_scheduler!(every: 100, initial_delay: 0)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 0})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end
  end

  describe "delay_mode" do
    test "regular" do
      scheduler = start_scheduler!(delay_mode: :regular, every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end

    test "shifted" do
      scheduler = start_scheduler!(delay_mode: :shifted, every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      refute_periodic_event(%{scheduler: ^scheduler, event: :next_tick})

      finish_job(job)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end
  end

  describe "job shutdown" do
    test "timeout when job doesn't trap exits" do
      {_scheduler, job} = start_job!(job_shutdown: 10, trap_exit?: false)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :shutdown}
    end

    test "timeout when job traps exits" do
      {_scheduler, job} = start_job!(job_shutdown: 10, trap_exit?: true)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :killed}
    end

    test "brutal_kill" do
      {_scheduler, job} = start_job!(job_shutdown: :brutal_kill, trap_exit?: true)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :killed}
    end

    test "infinity" do
      {scheduler, job} = start_job!(job_shutdown: :infinity, trap_exit?: true)

      mref = Process.monitor(scheduler)

      # Invoking asynchronously because this code blocks. Since the code is invoked from another
      # process, we have to use GenServer.stop.
      Task.start_link(fn -> GenServer.stop(scheduler) end)

      refute_receive {:DOWN, ^mref, :process, ^scheduler, _}

      send(job, :finish)
      assert_receive {:DOWN, ^mref, :process, ^scheduler, _}
    end
  end

  test "registered name" do
    scheduler = start_scheduler!(name: :registered_name)
    assert Process.whereis(:registered_name) == scheduler
    assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, name: :registered_name})
  end

  defp start_scheduler!(opts \\ []) do
    job_opts = Keyword.take(opts, [:trap_exit?])
    defaults = [id: :test_job, every: 1, mode: :manual, run: instrumented_job(job_opts)]
    start_supervised!({Periodic, Keyword.merge(defaults, opts)})
  end

  defp start_job!(opts \\ []) do
    scheduler = start_scheduler!(opts)
    tick(scheduler)
    assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    {scheduler, job}
  end

  defp instrumented_job(job_opts) do
    test_pid = self()

    fn ->
      Process.flag(:trap_exit, Keyword.get(job_opts, :trap_exit?, false))
      send(test_pid, {:started, self()})

      receive do
        :finish -> :ok
      end
    end
  end

  defp finish_job(job) do
    mref = Process.monitor(job)
    send(job, :finish)
    assert_receive {:DOWN, ^mref, :process, ^job, _}
    :ok
  end
end
