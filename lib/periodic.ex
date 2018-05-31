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

  ## Overlapped execution

  By default, the jobs are running as overlapped. This means that a new job
  instance will be started even if the previous one is not running. If you want
  to change that, you can pass the `overlap?: false` option.

  ## Disabling execution

  If you pass the `:infinity` as the timeout value, the job will not be executed.
  This can be useful to disable the job in some environments (e.g. in `:test`).

  ## Logging

  By default, nothing is logged. You can however, turn logging with `:log_level` and `:log_meta` options.
  See the timeout example for usage.

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
  job_id=my_job [debug] job timeout
  job_id=my_job [debug] starting the job
  job_id=my_job [debug] previous job still running, not starting another instance
  job_id=my_job [debug] job timeout
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
          every: duration,
          run: job_spec,
          overlap?: boolean,
          timeout: duration,
          log_level: nil | Logger.level(),
          log_meta: Keyword.t()
        ]
  @type duration :: non_neg_integer | :infinity
  @type job_spec :: (() -> term) | {module, atom, [term]}

  @doc "Starts the periodic executor."
  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts), do: Parent.GenServer.start_link(__MODULE__, Map.new(opts))

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
    enqueue_next(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:run_job, state) do
    maybe_start_job(state)
    enqueue_next(state)
    {:noreply, state}
  end

  def handle_info({:timeout, job_id}, state) do
    Parent.GenServer.shutdown_child(job_id)
    log(state, "job timeout")
    {:noreply, state}
  end

  def handle_info(unknown_message, state), do: super(unknown_message, state)

  @impl Parent.GenServer
  def handle_child_terminated(id, timer, _pid, _reason, state) do
    if timer != nil do
      Process.cancel_timer(timer)

      # flush the message if it's already in the mailbox
      receive do
        {:timeout, ^id} -> :ok
      after
        0 -> :ok
      end
    end

    log(state, "job finished")

    {:noreply, state}
  end

  defp defaults(), do: %{overlap?: true, timeout: :infinity, log_level: nil, log_meta: []}

  defp maybe_start_job(state) do
    if state.overlap? == true or not job_running?() do
      start_job(state)
    else
      log(state, "previous job still running, not starting another instance")
    end
  end

  defp job_running?(), do: Parent.GenServer.child?(:job)

  defp start_job(state) do
    log(state, "starting the job")
    id = if state.overlap?, do: make_ref(), else: :job
    job = state.run

    timer =
      if state.timeout != :infinity,
        do: Process.send_after(self(), {:timeout, id}, state.timeout),
        else: nil

    Parent.GenServer.start_child(%{
      id: id,
      start: {Task, :start_link, [fn -> invoke_job(job) end]},
      meta: timer,
      shutdown: :brutal_kill
    })
  end

  defp invoke_job({mod, fun, args}), do: apply(mod, fun, args)
  defp invoke_job(fun) when is_function(fun, 0), do: fun.()

  defp enqueue_next(%{every: :infinity}), do: :ok
  defp enqueue_next(state), do: Process.send_after(self(), :run_job, state.every)

  defp log(state, message) do
    if not is_nil(state.log_level), do: Logger.log(state.log_level, message, state.log_meta)
  end
end
