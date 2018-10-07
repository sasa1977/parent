defmodule PeriodicTest do
  use ExUnit.Case, async: true

  test "ticking with initial delay" do
    scheduler_pid = start_test_scheduler(initial_delay: 1, every: 2)

    assert next_tick(scheduler_pid).time_passed == 1
    assert next_tick(scheduler_pid).time_passed == 2
    assert next_tick(scheduler_pid).time_passed == 2
  end

  test "ticking without initial delay" do
    scheduler_pid = start_test_scheduler(every: 2)

    assert next_tick(scheduler_pid).time_passed == 2
    assert next_tick(scheduler_pid).time_passed == 2
  end

  test "nothing is executed if initial delay is infinity" do
    scheduler_pid = start_test_scheduler(initial_delay: :infinity, every: 2)
    refute_next_tick(scheduler_pid)
  end

  test "each job is started in a separate process" do
    scheduler_pid = start_test_scheduler(every: 1)

    next_tick(scheduler_pid)
    job_pid_1 = assert_job_started()

    next_tick(scheduler_pid)
    job_pid_2 = assert_job_started()

    assert job_pid_1 != scheduler_pid
    assert job_pid_2 != scheduler_pid
    assert job_pid_1 != job_pid_2
  end

  test "job is started on every interval if overlapping is allowed" do
    scheduler_pid = start_test_scheduler(every: 1, overlap?: true)

    next_tick(scheduler_pid)
    assert_job_started()

    next_tick(scheduler_pid)
    assert_job_started()
  end

  test "overlap is true by default" do
    scheduler_pid = start_test_scheduler(every: 1)

    next_tick(scheduler_pid)
    assert_job_started()

    next_tick(scheduler_pid)
    assert_job_started()
  end

  test "only one instance of job can run if overlapping is not allowed" do
    scheduler_pid = start_test_scheduler(every: 1, overlap?: false)

    next_tick(scheduler_pid)
    assert_job_started()

    next_tick(scheduler_pid)
    refute_job_started()
  end

  test "if overlapping is not allowed, next job is started after the previous one is done" do
    scheduler_pid = start_test_scheduler(every: 1, overlap?: false)

    next_tick(scheduler_pid)
    job_pid = assert_job_started()

    stop_job(job_pid)
    next_tick(scheduler_pid)

    assert_job_started()
  end

  test "job is killed if it times out" do
    scheduler_pid = start_test_scheduler(every: 1, timeout: 10)

    next_tick(scheduler_pid)
    job_pid = assert_job_started()

    mref = Process.monitor(job_pid)
    assert_receive {:DOWN, ^mref, :process, ^job_pid, _}
  end

  test "non-mocked periodical execution" do
    Periodic.start_link(every: 1, run: infinite_job())
    assert_job_started()
    assert_job_started()
  end

  defp start_test_scheduler(opts) do
    opts = Keyword.merge(opts, send_after_fun: test_send_after(), run: infinite_job())
    assert {:ok, scheduler_pid} = Periodic.start_link(opts)
    scheduler_pid
  end

  defp test_send_after() do
    test_process = self()

    fn pid, msg, delay ->
      send(test_process, {:send_after, %{pid: pid, msg: msg, delay: delay}})
    end
  end

  defp current_tick(scheduler_pid) do
    assert_receive {:send_after, %{pid: ^scheduler_pid} = send_after_data}
    send_after_data
  end

  defp refute_next_tick(scheduler_pid), do: refute_receive({:send_after, %{pid: ^scheduler_pid}})

  defp next_tick(scheduler_pid) do
    current_tick = current_tick(scheduler_pid)
    send(scheduler_pid, current_tick.msg)
    %{time_passed: current_tick.delay}
  end

  defp infinite_job() do
    owner = self()

    fn ->
      send(owner, {:test_job_started, self()})

      receive do
        :continue -> :ok
      end
    end
  end

  defp assert_job_started() do
    assert_receive {:test_job_started, pid}
    pid
  end

  defp refute_job_started(), do: refute_receive({:test_job_started, _pid})

  defp stop_job(job_pid) do
    mref = Process.monitor(job_pid)
    Process.exit(job_pid, :kill)
    assert_receive {:DOWN, ^mref, :process, pid, _reason}
  end
end
