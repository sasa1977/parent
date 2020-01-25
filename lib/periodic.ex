defmodule Periodic do
  @moduledoc """
  Periodic job execution.

  This module can be used when you need to periodically run some job.

  ## Quick start

  It is recommended (but not mandatory!) to define a dedicated module for the job. For example:

      defmodule MySystem.Cleanup do
        def child_spec(_arg) do
          Periodic.child_spec(
            id: __MODULE__,
            run: &cleanup/0,
            every: :timer.hours(1)
          )
        end

        defp cleanup(), do: # ...
      end

  With such module implemented, you can place the job in the desired place in the supervision tree:

      Supervisor.start_link(
        [
          MySystem.Cleanup,
          # ...
        ],
        # ...
      )

  You can of course start multiple periodic jobs in the system, and they don't have to be the
  children of the same supervisor. You're advised to place the job in the proper part of the
  supervision tree. For example, a database cleanup job should share the ancestor with the
  repo, while a periodic job working with Phoenix channels should share the ancestor with the
  endpoint.

  As mentioned, you don't need to create a dedicated module to run a job. It's also possible to
  provide `{Periodic, opts}` in the supervisor child list. Finally, if you need more runtime
  flexibility, you can also start the job with `start_link/1`.

  ## Process structure

  The process started with `start_link` is called the _scheduler_. This is the process which
  regularly "ticks" in the given interval and executes the _job_. The job is running in a separate
  one-off process, which is the child of the scheduler. When the job is done, the job process
  stops. Therefore, each execution is taking place in a separate process.

  Depending on the overlapping mode (see `:on_overlap` option), it is possible that multiple
  instances of the same job are running simultaneously.

  No other processes are started.

  ## Options

  - `:run` (required) - Zero arity function or MFA.
  - `:every` (required) - Time in milliseconds between two consecutive job executions (see
    `:delay_mode` option for details).
  - `:initial_delay` - Time in milliseconds before the first execution of the job. If not provided,
    the default value of `:every` is used. In other words, the first execution will by default
    take place after the desired interval has passed.
  - `:delay_mode` - Controls how the `:every` interval is interpreted. Following options are possible:
      - `:regular` (default) - `:every` represents the time between two consecutive starts
      - `:shifted` - `:every` represents the time between the termination of the previous
      and the start of the next instance.
  - `:on_overlap` - Defines the desired behaviour when the job is about to be started while the
    previous instance is still running.
      - `:run` (default) - always start the new job
      - `:ignore` - don't start the new job if the previous instance is still running
      - `:stop_previous` - stop the previous instance before starting the new one
  - `:timeout` - Defines the maximum running time of the job. If the job runs for longer than that,
    it is forcefully terminated. In this case, the job's shutdown specification is ignored.
    Defaults to `:infinity`
  - `:job_shutdown` - Shutdown value of the job process. See the "Shutdown" section
    for details.
  - `:id` - Supervisor child id of the scheduler process. Defaults to `Periodic`. If you plan on
    running multiple periodic jobs under the same supervisor, make sure that they have different
    id values.
  - `:name` - Registered name of the scheduler process. If not provided, the process will not be
    registered.
  - `:telemetry_id` - Id used in telemetry event names. See the "Telemetry" section for more
    details. If not provided, telemetry events won't be emitted.
  - `:mode` - When set to `:manual`, doesn't start jobs automatically, but instead relies on the
    external ticking mechanism. This should be used only in `:test` mix environment. See
    the "Testing" section for details.


  ## Shutdown

  To stop a particular job, you need to ask its parent supervisor to stop it using
  [Supervisor.terminate_child](https://hexdocs.pm/elixir/Supervisor.html#terminate_child/2).

  The scheduler process acts as a supervisor, and so it has the same shutdown behaviour. When
  ordered to terminate by its parent, the scheduler will stop currently running job instances
  according to the `:job_shutdown` configuration.

  The default behaviour is to wait for the job for 5 seconds. However, in order for this to
  waiting to actually happen, you need to invoke `Process.flag(:trap_exit, true)` from the run
  function.

  You can change the waiting time with the `:job_shutdown` option, which has the same semantics as
  in `Supervisor`. See [corresponding Supervisor documentation]
  (https://hexdocs.pm/elixir/Supervisor.html#module-shutdown-values-shutdown) for details.


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

  A basic logger is provided in `Periodic.Logger`. To use it, you need to provide the
  `:telemetry_id`, and then add logger handlers with `Periodic.Logger.install(telemetry_id)`.


  ## Testing

  The scheduler can be deterministically tested by setting the `:mode` option to `:manual`.
  In this mode, the scheduler won't tick on its own, and so it won't start any jobs unless
  instructed to by the client.

  The `:mode` should be set to `:manual` only in test mix environment. Here's a simple approach
  which doesn't require app env and config files:

      defmodule MyPeriodicJob do
        @mode if Mix.env() != :test, do: :auto, else: :manual

        def child_spec(_arg) do
          Periodic.child_spec(
            mode: @mode,
            name: __MODULE__,
            telemetry_id: __MODULE__
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

        setup do
          Periodic.Test.observe(MyPeriodicJob)
        end

        test "my periodic job" do
          bring_the_system_into_the_desired_state()

          Periodic.Test.tick(MyPeriodicJob)

          # wait for the job to finish successfully
          Periodic.Test.assert_periodic_event(MyPeriodicJob, :finished, %{reason: :normal})

          verify_side_effect_of_the_job()
        end
      end
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
          run: job_spec,
          delay_mode: :regular | :shifted,
          on_overlap: :run | :ignore | :stop_previous,
          timeout: pos_integer | :infinity,
          job_shutdown: :brutal_kill | :infinity | non_neg_integer()
        ]
  @type job_spec :: (() -> term) | {module, atom, [term]}

  @doc "Starts the periodic executor."
  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts) do
    gen_server_opts = Keyword.take(opts, [:name])
    Parent.GenServer.start_link(__MODULE__, normalize_opts(opts), gen_server_opts)
  end

  defp normalize_opts(opts) do
    opts = Map.new(opts)

    with %{overlap?: overlap?} <- opts do
      Logger.warn("The `:overlap?` option is deprecated, use `:on_overlap` instead.")

      opts
      |> Map.put(:on_overlap, if(overlap?, do: :run, else: :ignore))
      |> Map.delete(:overlap?)
    end
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
    state = defaults() |> Map.merge(opts) |> Map.put(:timer, nil)
    {initial_delay, state} = Map.pop(state, :initial_delay, state.every)
    enqueue_next_tick(state, initial_delay)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    handle_tick(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, %{mode: :manual} = state) do
    handle_tick(state)
    {:reply, :ok, state}
  end

  @impl Parent.GenServer
  def handle_child_terminated(_id, meta, pid, reason, state) do
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
      send_after_fun: &Process.send_after/3,
      job_shutdown: :timer.seconds(5)
    }
  end

  defp handle_tick(state) do
    if state.delay_mode == :regular, do: enqueue_next_tick(state, state.every)

    case state.on_overlap do
      :run ->
        start_job(state)

      :ignore ->
        case previous_instance() do
          {:ok, pid} -> telemetry(state, :skipped, %{still_running: pid})
          :error -> start_job(state)
        end

      :stop_previous ->
        with {:ok, pid} <- previous_instance() do
          Parent.GenServer.shutdown_all(:kill)
          telemetry(state, :stopped_previous, %{pid: pid})
        end

        start_job(state)
    end
  end

  defp previous_instance() do
    case Parent.GenServer.children() do
      [{_id, pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp start_job(state) do
    job = state.run

    with {:ok, pid} <-
           Parent.GenServer.start_child(%{
             id: make_ref(),
             start: {Task, :start_link, [fn -> invoke_job(job) end]},
             timeout: state.timeout,
             shutdown: state.job_shutdown,
             meta: %{started_at: :erlang.monotonic_time()}
           }),
         do: telemetry(state, :started, %{job: pid})
  end

  defp invoke_job({mod, fun, args}), do: apply(mod, fun, args)
  defp invoke_job(fun) when is_function(fun, 0), do: fun.()

  defp enqueue_next_tick(state, delay) do
    telemetry(state, :next_tick, %{in: delay})
    if state.mode == :auto, do: state.send_after_fun.(self(), :tick, delay)
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
