defmodule Periodic do
  @moduledoc """
  Periodic job execution.

  This module can be used when you need to periodically run some code in a
  separate process.

  To setup the job execution, you can include the child_spec in your supervision
  tree. The childspec has the following shape:

  ```
  {Periodic, run: mfa_or_zero_arity_lambda, every: interval}
  ```

  For example:

  ```
  Supervisor.start_link(
    [{Periodic, run: {IO, :puts, ["Hello, World!"]}, every: :timer.seconds(1)}],
    strategy: :one_for_one
  )

  Hello, World!   # after one second
  Hello, World!   # after two seconds
  ...
  ```

  By default the first execution will occur after the `every` interval. To override this
  you can set the `initial_delay` option:

  ```
  Supervisor.start_link(
    [
      {Periodic,
       run: {IO, :puts, ["Hello, World!"]},
       initial_delay: :timer.seconds(1),
       every: :timer.seconds(10)}
    ],
    strategy: :one_for_one
  )

  Hello, World!   # after one second
  Hello, World!   # after ten seconds
  ```

  ## Multiple children under the same supervisor

  You can start multiple periodic tasks under the same supervisor. However,
  in this case you need to provide a unique id for each task, which is used as
  the supervisor child id:

  ```
  Supervisor.start_link(
    [
      {Periodic, id: :job1, run: {IO, :puts, ["Hi!"]}, every: :timer.seconds(1)},
      {Periodic, id: :job2, run: {IO, :puts, ["Hello!"]}, every: :timer.seconds(2)}
    ],
    strategy: :one_for_one
  )

  Hi!
  Hello!
  Hi!
  Hi!
  Hello!
  ...
  ```

  ## Delay mode

  The `:delay_mode` option can be used to configure how the `:every` option is
  interpreted. It can have the following values:

    - `:regular` - The `:every` option represents the time between two
                   consecutive starts of the job. This is the default value.
    - `:shifted` - The `:every` option represents the time between the
                   termination of the job and the start of the next instance.

  Keep in mind that, regardless of the delay mode, `Periodic` doesn't attempt
  to correct a time skew between executions. Even in the regular mode, the
  delay between two consecutive jobs might be higher than specified, for example
  if the system is overloaded. If such higher delay happens, it will not be
  compensated for.

  ## Overlapped execution

  By default, the jobs are running as overlapped. This means that a new job
  instance will be started even if the previous one is not running. If you want
  to change that, you can use the `:on_overlap` option which can have the
  following values:

    - `:run` - The new job instance is always started. This is the default value.
    - `:ignore` - New job instance is not started if the previous one is
                  still running.
    - `:stop_previous` - Previous job instances are terminated before the new
                         one is started. In this case, the previous job will be
                         brutally killed.

  Note that this option only makes sense if `:delay_mode` is set to `:regular`.

  ## Disabling execution

  If you pass the `:infinity` as the timeout value, the job will not be executed.
  This can be useful to disable the job in some environments (e.g. in `:test`).

  ## Logging

  By default, nothing is logged. You can however, turn logging with `:log_level`
  and `:log_meta` options. See the timeout example for usage.

  ## Timeout

  You can also pass the :timeout option:

  ```
  Supervisor.start_link(
    [
      {Periodic,
        run: {Process, :sleep, [:infinity]}, every: :timer.seconds(1),
        overlap?: false,
        timeout: :timer.seconds(2),
        strategy: :one_for_one,
        log_level: :debug,
        log_meta: [job_id: :my_job]
      }
    ],
    strategy: :one_for_one
  )

  job_id=my_job [debug] starting the job
  job_id=my_job [debug] previous job still running, not starting another instance
  job_id=my_job [debug] job failed with the reason `:timeout`
  job_id=my_job [debug] starting the job
  job_id=my_job [debug] previous job still running, not starting another instance
  job_id=my_job [debug] job failed with the reason `:timeout`
  ...
  ```

  ## Shutdown

  Since periodic executor is a plain supervisor child, shutting down is not
  explicitly supported. If you want to stop the job, just take it down via its
  supervisor, or shut down either of its ancestors.
  """
  use Parent.GenServer
  require Logger

  @type opts :: [
          id: term,
          name: GenServer.name(),
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

    telemetry(state, :finished, %{time: duration}, %{job: pid, reason: reason})
    {:noreply, state}
  end

  defp defaults() do
    %{
      mode: :auto,
      delay_mode: :regular,
      on_overlap: :run,
      timeout: :infinity,
      log_level: nil,
      log_meta: [],
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
          telemetry(state, :killed_previous, %{pid: pid})
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

  if Mix.env() != :test do
    defp telemetry(state, :next_tick, _measurements), do: :ok
  end

  defp telemetry(state, event, measurements \\ %{}, meta) do
    data =
      meta
      |> Map.merge(Map.take(state, ~w/id name/a))
      |> Map.merge(%{event: event, scheduler: self()})

    :telemetry.execute(
      [__MODULE__],
      measurements,
      data
    )
  end
end
