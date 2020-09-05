defmodule Periodic.LoggerTest do
  use ExUnit.Case, async: false
  import Parent.CaptureLog
  import Periodic.Test
  import Periodic.TestHelper

  setup_all do
    Periodic.Logger.install(:test_job)
  end

  setup do
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :warn) end)
    observe(:test_job)
  end

  test "start" do
    message = capture_log(fn -> start_job!() end)
    assert message =~ ~r/Periodic\(:test_job\): job #PID<.+> started/
  end

  describe "finished" do
    test "normal" do
      message =
        capture_log(fn ->
          {_scheduler, job} = start_job!()
          finish_job(job)
          assert_periodic_event(:test_job, :finished, %{job: ^job})
        end)

      assert message =~ ~r/Periodic\(:test_job\): job #PID<.+> finished, duration=\d+us/
    end

    test "shutdown" do
      message =
        capture_log(fn ->
          {_scheduler, job} = start_job!()
          Process.exit(job, :shutdown)
          assert_periodic_event(:test_job, :finished, %{job: ^job})
        end)

      assert message =~ ~r/Periodic\(:test_job\): job #PID<.+> shut down/
    end

    test "kill" do
      message =
        capture_log(fn ->
          {_scheduler, job} = start_job!()
          Process.exit(job, :kill)
          assert_periodic_event(:test_job, :finished, %{job: ^job})
        end)

      assert message =~ ~r/Periodic\(:test_job\): job #PID<.+> killed/
    end

    test "crash" do
      message =
        capture_log(fn ->
          {_scheduler, job} = start_job!()
          send(job, {:crash, :some_reason})
          assert_periodic_event(:test_job, :finished, %{job: ^job})
        end)

      assert message =~ ~r/Periodic\(:test_job\): job #PID<.+> exited with reason :some_reason/
    end
  end

  test "skipped" do
    message =
      capture_log(fn ->
        {scheduler, _job} = start_job!(on_overlap: :ignore)
        tick(scheduler)
        assert_periodic_event(:test_job, :skipped, %{scheduler: ^scheduler})
      end)

    assert message =~ "skipped starting the job because the previous instance is still running"
  end

  test "stopped_previous" do
    message =
      capture_log(fn ->
        {scheduler, _job} = start_job!(on_overlap: :stop_previous)
        tick(scheduler)
      end)

    assert message =~ "killed previous job instance, because the new job is about to be started"
  end
end
