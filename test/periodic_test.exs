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
    scheduler = start_job!()

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
    scheduler = start_job!()
    tick(scheduler)
    assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})

    finish_job(job)
    assert_periodic_event(%{scheduler: ^scheduler, event: :finished, job: ^job}, %{time: time})
    assert is_integer(time) and time > 0
  end

  describe "on_overlap" do
    test "ignore" do
      scheduler = start_job!(on_overlap: :ignore)

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      assert_receive {:started, ^job}

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :skipped, still_running: ^job})
      refute_periodic_event(%{scheduler: ^scheduler, event: :started})
      refute_received {:started, _}

      finish_job(job)
      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      assert_receive {:started, ^job}
    end

    test "stop_previous" do
      scheduler = start_job!(on_overlap: :stop_previous)

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      assert_receive {:started, ^job}
      mref = Process.monitor(job)

      tick(scheduler)
      assert_receive({:DOWN, ^mref, :process, ^job, :killed})
      assert_periodic_event(%{scheduler: ^scheduler, event: :killed_previous, pid: ^job})
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      assert_receive {:started, ^job}
    end
  end

  test "timeout" do
    scheduler = start_job!(timeout: 1)
    tick(scheduler)
    assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
    mref = Process.monitor(job)
    assert_receive({:DOWN, ^mref, :process, ^job, :killed})
  end

  describe "initial_delay" do
    test "is by default equal to the interval" do
      scheduler = start_job!(every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end

    test "overrides the first tick interval" do
      scheduler = start_job!(every: 100, initial_delay: 0)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 0})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end
  end

  describe "delay_mode" do
    test "regular" do
      scheduler = start_job!(delay_mode: :regular, every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end

    test "shifted" do
      scheduler = start_job!(delay_mode: :shifted, every: 100)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})

      tick(scheduler)
      assert_periodic_event(%{scheduler: ^scheduler, event: :started, job: job})
      refute_periodic_event(%{scheduler: ^scheduler, event: :next_tick})

      finish_job(job)
      assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, in: 100})
    end
  end

  test "registered name" do
    scheduler = start_job!(name: :registered_name)
    assert Process.whereis(:registered_name) == scheduler
    assert_periodic_event(%{scheduler: ^scheduler, event: :next_tick, name: :registered_name})
  end

  defp start_job!(opts \\ []) do
    defaults = [id: :test_job, every: 1, mode: :manual, run: instrumented_job()]
    {:ok, pid} = start_supervised({Periodic, Keyword.merge(defaults, opts)})
    pid
  end

  defp instrumented_job() do
    test_pid = self()

    fn ->
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
