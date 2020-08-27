defmodule Periodic do
  @moduledoc """
  Periodic job execution.

  ## Quick start

  It is recommended (but not required) to implement the job in a dedicated module. For example:

      defmodule SomeCleanup do
        def child_spec(_arg) do
          Periodic.child_spec(
            id: __MODULE__,
            run: &run/0,
            every: :timer.hours(1)
          )
        end

        defp run(), do: # ...
      end

  With such module implemented, you can place the job somewhere in the supervision tree:

      Supervisor.start_link(
        [
          SomeCleanup,
          # ...
        ],
        # ...
      )

  You can of course start multiple periodic jobs in the system, and they don't have to be the
  children of the same supervisor. You're advised to place the job in the proper part of the
  supervision tree. For example, a database cleanup job should share the ancestor with the
  repo, while a job working with Phoenix channels should share the ancestor with the
  endpoint.

  As mentioned, you don't need to create a dedicated module to run a job. It's also possible to
  provide `{Periodic, opts}` in the supervisor child list. Finally, if you need more runtime
  flexibility, you can also start the job with `start_link/1`.


  ## Process structure

  The process started with `start_link` is called the _scheduler_. This is the process which
  regularly "ticks" in the given interval and executes the _job_. The job is executed in a separate
  one-off process, which is the child of the scheduler. When the job is done, the job process
  stops. Therefore, each job instance is running in a separate process.

  Depending on the overlapping mode (see the `:on_overlap` option), it can happen that multiple
  instances of the same job are running simultaneously.


  ## Options

  - `:run` (required) - Zero arity function or MFA invoked to run the job. This function is
    invoked in a separate one-off process which is a child of the scheduler.
  - `:every` (required) - Time in milliseconds between two consecutive job executions (see
    `:delay_mode` option for details).
  - `:initial_delay` - Time in milliseconds before the first execution of the job. If not provided,
    the default value of `:every` is used. In other words, the first execution will by default
    take place after the `:initial_delay` interval has passed.
  - `:delay_mode` - Controls how the `:every` interval is interpreted. Following options are
    possible:
      - `:regular` (default) - `:every` represents the time between two consecutive starts
      - `:shifted` - `:every` represents the time between the termination of the previous and the
        start of the next instance.

    See the "Delay mode" section for more details.
  - `:when` - Function which acts as an additional runtime guard to decide if the job will be
    started. This can be useful for implementing fixed scheduled jobs. See the "Fixed scheduling"
    section for details.
  - `:on_overlap` - Defines the desired behaviour when the job is about to be started while the
    previous instance is still running.
      - `:run` (default) - always start the new job
      - `:ignore` - don't start the new job if the previous instance is still running
      - `:stop_previous` - stop the previous instance before starting the new one
  - `:timeout` - Defines the maximum running time of the job. If the job doesn't finish in the
    given time, it is forcefully terminated. In this case, the job's shutdown specification is
    ignored. Defaults to `:infinity`
  - `:job_shutdown` - Shutdown value of the job process. See the "Shutdown" section
    for details.
  - `:id` - Supervisor child id of the scheduler process. Defaults to `Periodic`. If you plan on
    running multiple periodic jobs under the same supervisor, make sure that they have different
    id values.
  - `:name` - Registered name of the scheduler process. If not provided, the process will not be
    registered.
  - `:telemetry_id` - Id used in telemetry event names. See the "Telemetry" section for more
    details. If not provided, telemetry events won't be emitted.
  - `:mode` - When set to `:manual`, the jobs won't be started automatically. Instead you have to
    manually send tick signals to the scheduler. This should be used only in `:test` mix env. See
    the "Testing" section for details.


  ## Delay mode

  In the `:regular` mode (which is the default), the interval indicates time between two
  consecutive starts. This mode is typically useful if you want to maintain a stable execution
  rate (the number of executions per some time period). It is also a better choice if you're
  implementing fixed scheduling, as advised in the "Fixed scheduling" section.

  In the `:shifted` mode the interval represents the pause time between the end of the job and the
  start of the next one. This mode is likely a better choice if you want to have a fixed "cool off"
  period between two consecutive executions, to reduce the load on the system.

  Internally, Periodic relies on Erlang's monotonic time, which improves rate stability regardless
  of system time changes (see [Time correction](http://erlang.org/doc/apps/erts/time_correction.html#time-correction)).
  Consider using the "Multi-time warp mode" (see [here](http://erlang.org/doc/apps/erts/time_correction.html#time-warp-modes))
  to further improve rate stability in the situations when system time changes.

  In general, the overhead introduced by Periodic as well as job processing will be compensated,
  and you can usually expect stable intervals with very small variations (typically in sub
  milliseconds range), and no steady shift over time. However, in some cases, for example when the
  system is overloaded, the variations might be more significant.

  In the `:shifted` mode the job duration will affect the execution of the next job. In addition,
  Periodic will induce a slight (usually less than 100 microseconds), but a steady skew, due to
  its own internal processing.


  ## Shutdown

  To stop the scheduler, you need to ask its parent supervisor to stop the scheduler using
  [Supervisor.terminate_child](https://hexdocs.pm/elixir/Supervisor.html#terminate_child/2).

  The scheduler process acts as a supervisor, and so it has the same shutdown behaviour. When
  ordered to terminate by its parent, the scheduler will stop currently running job instances
  according to the `:job_shutdown` configuration.

  The default behaviour is to wait 5 seconds for the job to finish. However, in order for this
  waiting to actually happen, you need to invoke `Process.flag(:trap_exit, true)` from the run
  function.

  You can change the waiting time with the `:job_shutdown` option, which has the same semantics as
  in `Supervisor`. See [corresponding Supervisor documentation]
  (https://hexdocs.pm/elixir/Supervisor.html#module-shutdown-values-shutdown) for details.


  ## Fixed scheduling

  Periodic doesn't have explicit support for scheduling jobs at some particular time (e.g. every
  day at midnight). However, you can implement this on top of the provided functionality using
  the `:when` option

      defmodule SomeCleanup do
        def child_spec(_arg) do
          Periodic.child_spec(
            # check every minute if we need to run the cleanup
            every: :timer.minutes(1),

            # start the job only if it's midnight
            when: fn -> match?(%Time{hour: 0, minute: 0}, Time.utc_now()) end,

            # ...
          )
        end

        # ...
      end

  Note that the execution guarantees here are "at most once". If the system is down at the
  scheduled time, the job won't be executed. Stronger guarantees can be obtained by basing the
  conditional logic on some persistence mechanism.

  Note that the `:when` guard is executed in the scheduler process. If the guard execution time is
  larger than the ticking period, time drifts will occur.


  ## Telemetry

  The scheduler optionally emits telemetry events. To configure telemetry you need to provide
  the `:telemetry_id` option. For example:

      Periodic.start_link(telemetry_id: :db_cleanup, ...)

  This will emit various events in the shape of `[Periodic, telemetry_id, event]`. Currently
  supported events are:

  - `:started` - a new job instance is started
  - `:finished` - job instance has finished or crashed (see related metadata for the reason)
  - `:skipped` - new instance hasn't been started because the previous one is still running
  - `:stopped_previous` - previous instance has been stopped because the new one is about to be
    started

  To consume the desired events, install the corresponding telemetry handler.


  ## Logging

  Basic logger is provided in `Periodic.Logger`. To use it, the scheduler needs to be started with
  the `:telemetry_id` option.

  To install logger handlers, you can invoke `Periodic.Logger.install(telemetry_id)`. This function
  should be invoked only once per each scheduler during the system lifetime, preferably before the
  scheduler is started. A convenient place to do it is your application start callback.


  ## Testing

  The scheduler can be deterministically tested by setting the `:mode` option to `:manual`.
  In this mode, the scheduler won't tick on its own, and so it won't start any jobs unless
  instructed to by the client code.

  The `:mode` should be set to `:manual` only in test mix environment. Here's a simple approach
  which doesn't require app env and config files:

      defmodule MyPeriodicJob do
        @mode if Mix.env() != :test, do: :auto, else: :manual

        def child_spec(_arg) do
          Periodic.child_spec(
            mode: @mode,
            name: __MODULE__,
            # ...
          )
        end

        # ...
      end

  Of course, you can alternatively use app env or any other approach you prefer. Just make sure
  to set the mode to manual only in test env.

  Notice that we're also setting the registered name and telemetry id. We'll need both to
  interact with the scheduler

  With such setup in place, the general shape of the periodic job test would look like this:

      def MyPeriodicJobTest do
        use ExUnit.Case, async: true
        require Periodic.Test

        test "my periodic job" do
          bring_the_system_into_the_desired_state()

          # tick the scheduler
          assert Periodic.Test.sync_tick(MyPeriodicJob) == {:ok, :normal}

          verify_side_effect_of_the_job()
        end
      end

  Note that this won't suffice for fixed schedules. Consider again the cleanup job which runs
  at midnight:

      defmodule SomeCleanup do
        def child_spec(_arg) do
          Periodic.child_spec(
            every: :timer.minutes(1),
            when: fn -> match?(%Time{hour: 0, minute: 0}, Time.utc_now()) end,

            # ...
          )
        end

        # ...
      end

  Manually ticking won't start the job, unless the test is running exactly at midnight. To make
  this module testable, you need to use a different implementation of `:when` in test environment:

      defmodule SomeCleanup do
        def child_spec(_arg) do
          Periodic.child_spec(
            every: :timer.minutes(1),
            when: &should_run?/0

            # ...
          )
        end

        if Mix.env() != :test do
          defp should_run?(), do: match?(%Time{hour: 0, minute: 0}, Time.utc_now())
        else
          defp should_run?(), do: true
        end

        # ...
      end


  ## Comparison to other schedulers

  There are various other abstractions for running periodic jobs in BEAM, such as:

    - the built-in [:timer](https://erlang.org/doc/man/timer.html) module from Erlang stdlib
    - [erlcron](https://github.com/erlware/erlcron)
    - [quantum](https://hexdocs.pm/quantum/readme.html)
    - [Oban](https://hexdocs.pm/oban/Oban.html#module-periodic-cron-jobs)

  Compared to `:timer`, Periodic offers some additional features, such as overlap handling,
  distributed scheduling, and telemetry support.

  Compared to most other third party libraries, Periodic will likely provide much less features
  out of the box. So in some situations, such as database persistence or back-pressure, you might
  need to invest more effort with Periodic. On the plus side Periodic should be simpler to use
  in typical scenarios, and much easier to reason about, while still providing enough flexibility
  to handle arbitrarily complex scenarios.

  For a more detailed discussion, see [this blog post](https://www.theerlangelist.com/article/periodic).
  """
  use Parent.GenServer
  require Logger

  @type opts :: [
          id: term,
          name: GenServer.name(),
          telemetry_id: term,
          mode: :auto | :manual,
          every: pos_integer,
          initial_delay: non_neg_integer,
          delay_mode: :regular | :shifted,
          run: (() -> term) | {module, atom, [term]},
          when: (() -> boolean) | {module, atom, [term]},
          on_overlap: :run | :ignore | :stop_previous,
          timeout: pos_integer | :infinity,
          job_shutdown: :brutal_kill | :infinity | non_neg_integer()
        ]

  @doc "Starts the periodic executor."
  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts) do
    gen_server_opts = Keyword.take(opts, [:name])
    Parent.GenServer.start_link(__MODULE__, Map.new(opts), gen_server_opts)
  end

  @doc "Builds a child specification for starting the periodic executor."
  @spec child_spec(opts) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :id, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = Map.merge(defaults(), opts)
    {initial_delay, state} = Map.pop(state, :initial_delay, state.every)
    enqueue_next_tick(state, initial_delay)
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:tick, expected_now}, state) do
    handle_tick(state, now: expected_now)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:tick, opts}, from, %{mode: :manual} = state) do
    caller = if Keyword.get(opts, :await_job?), do: from, else: nil
    response = handle_tick(state, caller: caller)

    cond do
      is_nil(caller) -> {:reply, :ok, state}
      match?({:ok, _pid}, response) -> {:noreply, state}
      true -> {:reply, {:error, :job_not_started}, state}
    end
  end

  @impl Parent.GenServer
  def handle_child_terminated(_id, meta, pid, reason, state) do
    with from when not is_nil(from) <- meta.caller, do: GenServer.reply(from, {:ok, reason})
    if state.delay_mode == :shifted, do: enqueue_next_tick(state, state.every)

    duration =
      :erlang.convert_time_unit(
        :erlang.monotonic_time() - meta.started_at,
        :native,
        :microsecond
      )

    telemetry(state, :finished, %{job: pid, reason: reason}, %{time: duration})
    {:noreply, state}
  end

  defp defaults() do
    %{
      telemetry_id: nil,
      mode: :auto,
      delay_mode: :regular,
      on_overlap: :run,
      timeout: :infinity,
      job_shutdown: :timer.seconds(5),
      when: nil
    }
  end

  defp handle_tick(state, opts) do
    if state.delay_mode == :regular, do: enqueue_next_tick(state, state.every, opts)
    if job_guard_satisfied?(state), do: start_job(state, opts)
  end

  defp job_guard_satisfied?(%{when: nil}), do: true
  defp job_guard_satisfied?(%{when: {m, f, a}}), do: apply(m, f, a)
  defp job_guard_satisfied?(%{when: fun}) when is_function(fun), do: fun.()

  defp start_job(%{on_overlap: :run} = state, opts),
    do: start_job_process(state, opts)

  defp start_job(%{on_overlap: :ignore} = state, opts) do
    case previous_instance() do
      {:ok, pid} ->
        telemetry(state, :skipped, %{still_running: pid})
        nil

      :error ->
        start_job_process(state, opts)
    end
  end

  defp start_job(%{on_overlap: :stop_previous} = state, opts) do
    with {:ok, pid} <- previous_instance() do
      Parent.shutdown_all(:kill)
      telemetry(state, :stopped_previous, %{pid: pid})
    end

    start_job_process(state, opts)
  end

  defp start_job_process(state, opts) do
    job = state.run

    with {:ok, pid} <-
           Parent.start_child(%{
             id: make_ref(),
             start: {Task, :start_link, [fn -> invoke_job(job) end]},
             timeout: state.timeout,
             shutdown: state.job_shutdown,
             meta: %{started_at: :erlang.monotonic_time(), caller: Keyword.get(opts, :caller)}
           }) do
      telemetry(state, :started, %{job: pid})
      {:ok, pid}
    end
  end

  defp invoke_job({mod, fun, args}), do: apply(mod, fun, args)
  defp invoke_job(fun) when is_function(fun, 0), do: fun.()

  defp previous_instance() do
    case Parent.children() do
      [{_id, pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp enqueue_next_tick(state, delay, opts \\ []) do
    telemetry(state, :next_tick, %{in: delay})

    if state.mode == :auto do
      now = Keyword.get_lazy(opts, :now, fn -> :erlang.monotonic_time(:millisecond) end)
      next_tick_abs_time = now + delay
      Process.send_after(self(), {:tick, next_tick_abs_time}, next_tick_abs_time, abs: true)
    end
  end

  defp telemetry(state, event, data, measurements \\ %{})

  if Mix.env() != :test do
    defp telemetry(_state, :next_tick, _data, _measurements), do: :ok
  end

  defp telemetry(%{telemetry_id: nil}, _event, _data, _measurements), do: :ok

  defp telemetry(state, event, data, measurements) do
    :telemetry.execute(
      [__MODULE__, state.telemetry_id, event],
      measurements,
      Map.merge(data, %{scheduler: self()})
    )
  end
end
