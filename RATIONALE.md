# Rationale

When it comes to OTP supervision trees, the usual good practice is to run each process under some supervisor. In other words, a process which is a parent of other processes should most often be a supervisor. While this is most often a good approach, there are some cases where it's better to start processes directly under a GenServer or some other non-supervisor.

Direct parenting requires the implementation to take some roles of the supervisor. The process should usually trap exits, keep track of its child processes, and ensure that all child processes are terminated before the parent itself stops.

While this is not very hard to implement (and I advise doing it for practice), it will lead to some boilerplate. I've personally encountered a couple of cases where I needed to code this from scratch, and it took some time and careful programming to get it right. The parent library is an attempt to extract the typical implementation into a common behaviour.

Currently, the only provided behaviour is `Parent.GenServer`, which is basically a GenServer with built-in support for parenting. It's possible to create other behaviours (e.g. `Parent.GenStage` or `Parent.GenStatem`), but since I'm still not clear about the utility and the interface, I'm keeping the scope small for the moment.

## Parent.GenServer

`Parent.GenServer` is a specialization of a GenServer. You can think of it as a mixture of GenServer, Supervisor, and Registry. The behaviour allows you to implement a server process which needs to parent one or more child processes, which can be started and stopped on-demand.

The behaviour is used in a standard way:

```elixir
defmodule MyParentServer do
  use Parent.GenServer

  # ...
end
```

Once the behaviour is used, you can work with your module as if it was a GenServer. In other words you can use all the functions from the Elixir's GenServer module, and implement the same callbacks (e.g. `init/1`, `handle_call/3`, ...) with exactly the same interface and semantics.

However, there are some differences: a server powered by `Parent.GenServer` by default traps exits. The behaviour will also take down all the known child processes on termination. Finally, the default version of injected `child_spec/1` uses `:infinity` as the shutdown value.

The principal feature of `Parent.GenServer` is the ability to start immediate child processes. This can be done with `start_child/1`, which must be invoked in the server process. The function takes a child specification as its single argument. The specification is a variation of a child spec map used with supervisors. In its full shape the child spec has the following type specification:

```elixir
%{
  :id => term,
  start => {module, atom, [arg :: term]} | (() -> {:ok, pid} | error :: term),
  optional(:shutdown) => non_neg_integer | :infinity | :brutal_kill,
  optional(:meta) => term
}
```

The shutdown field is optional, and if omitted, the default value of 5000 (5 seconds) is used. Just like with supervisors, a child spec can also be provided in the shape of `{module, arg :: term}` or `module`.

The optional meta field can be used to associate arbitrary metadata to the child.

Therefore, to start a task as a single child, you can write:

```elixir
defmodule MyParentServer do
  use Parent.GenServer

  def init(_) do
    {:ok, _child_pid} =
      Parent.GenServer.start_child(%{
        id: :hello_world,
        start: {Task, :start_link, [fn -> IO.puts "Hello, World!" end]}
      })

    {:ok, nil}
  end
end
```

And now, to start the parent server, you can invoke `Parent.GenServer.start_link(MyParentServer, nil)`.

Once a process is started, casts and calls are issued through Elixir's GenServer module. The `Parent.GenServer` module doesn't export any function which can be used to manipulate the parent server from the outside. So to reiterate: a `Parent.GenServer` is essentially a GenServer.

You might wonder what's the benefit of `start_child/1` vs plain `Task.start_link`. The first benefit is that any child started through `start_child/1` is known to the  behaviour. Therefore, while terminating, the behaviour will make sure to take all the child processes down. This guarantees that if the parent is taken down, the child processes will not be left lingering.

Another benefit is that you can use other `Parent.GenServer` functions to work with child processes started with `start_child/1`. You can enumerate the child processes, fetch individual children by their id, and know the count of alive child processes. This is where `Parent.GenServer` serves as a kind of a unique registry.

Finally, if a child terminates, the behaviour will handle the corresponding `:EXIT` message, and convert it into the callback `handle_child_terminated(child_name :: term, meta :: term, pid, reason :: term, state)`. This is the only callback specific to `Parent.GenServer`.

This pretty much covers the `Parent.GenServer` behaviour. In my opinion, it's a fairly lightweight variation of the standard GenServer, which makes it fairly easy to reason about (assuming the user is already familiar with GenServer). However, before looking at use cases, let's discuss one controversial implementation detail.

### State management

Careful readers might have noticed that the behaviour manages its state implicitly. When `Parent.GenServer.start_child/1` succeeds, the function returns `{:ok, pid}`, while the internal behaviour state is implicitly changed. In other words, `start_child/1` is a function with a side-effect.

The main reason why this approach is chosen is because starting of a child is by itself a side-effect operation. Thus, as soon as the new child is started, we want it to be included in other behaviour functions (e.g. when enumerating child processes or mapping a name to a pid). Using implicit state allows exactly this and leaves no place for mistakes. As an added bonus, the implicit state simplifies the interface of the callbacks, and allows `Parent.GenServer` to work exactly as a GenServer, which simplifies the transition to a parented version, and lowers the learning curve.

For state storage, the behaviour uses the controversial process dictionary. This approach is chosen, since it keeps the entire state inside the process, so there's no data-copying involved nor are extra BEAM resources used (which would be the case if ETS or e.g. Agent was chosen).

## Examples

Before looking at candidate examples, I want to reiterate that `Parent.GenServer` does not intend to replace supervisors. As mentioned in the introduction, in most cases you should run the workers directly under a supervisor. That said, I've encountered some cases where it was better to directly parent some processes. In most of such cases, I've noticed the following properties:

- The parent needs to detect termination of its child and perform some arbitrary logic when it happens.
- Children are one-off jobs which finish in a finite amount of time.
- Children are not used as servers for other processes in the system. However, in some cases they might be powered by server behaviours such as GenServer.

The concrete examples I've seen include periodic job execution, cancelable jobs with timeout, and job queues. Let's see how each example can be handled with the parent library.

### Periodic job execution

The task at hand is to periodically (say every x seconds) run some job. It could be a cleanup job, communication with an external service, or anything else.

Let's forget for the moment the existence of 3rd party libraries which cover this case, such as [quantum](https://hex.pm/packages/quantum) (I'll discuss the differences from quantum a bit later). Here's one way to implement this:

```elixir
Task.start_link(fn ->
  fn ->
    Process.sleep(:timer.seconds(5))
    do_something()
  end
  |> Stream.repeatedly()
  |> Stream.run()
end)
```

This is definitely a simple solution which works out of the box. I occasionally use this approach and it works well in simple cases.

However, there are some possible problems, depending on what `do_something` does. One issue is that if the job function crashes, the periodic job is also taken down. The supervisor will restart the process, but we need to be careful not to trip maximum restart intensity. In addition, this implementation has a problem of a possible drift. A long running computation might postpone the next job execution. If the computation gets stuck forever, `do_something` will not be executed anymore. Even crashes and restarts might cause some drift. Finally, if `do_something` allocates a lot of memory, it might put a pressure on the garbage collector, or lead to increased memory consumption.

These issues can be solved if "ticking" is separated from the job execution. In other words, we'd use one process, let's call it ticker, which start the job as a separate process every five seconds.

If you want to follow the standard OTP way, where every worker is parented by a supervisor, you'd likely need two supervisors here. Here's the supervision tree:

```
    TopSupervisor (one_for_all)
       /             \
JobSupervisor      Ticker (GenServer)
      |
  Job (Task)
```

The reason why we need `TopSupervisor` is to allow us to properly stop the periodic job execution without stopping anything else in the system. The reason why it's one_for_all is to prevent us from running multiple instances of the same job, if e.g. ticker is restarted.

This is a fairly complex process structure for something as simple as "invoke some function every X seconds". Moreover, these supervisors don't really lift much (if any) responsibilities from the ticker server. For example, if you don't want to prevent overlaps (running two instances of the same job at the same time), the ticker needs to keep track of currently running jobs, which means it will have to monitor them, and handle corresponding `:DOWN` messages. This will add some complexity to a server with a fairly simple basic role (start a job every X seconds).

Therefore, I usually resort to starting a job as a direct child under the ticker process. This will simplify the supervision tree, but it will still require some complexity in the ticker server.

The `Parent.GenServer` can help us here. Here's a naive implementation, which starts a job every second. The job generates a random number `x` in the range of 1-2000, then sleeps for `x` milliseconds, and prints the number. The ticker will not start another job if the previous one is still running:

```elixir
defmodule Demo.Periodic do
  use Parent.GenServer

  def start_link(), do: Parent.GenServer.start_link(__MODULE__, nil)

  @impl GenServer
  def init(_) do
    :timer.send_interval(:timer.seconds(1), :run_job)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:run_job, state) do
    if Parent.GenServer.child?(:job) do
      IO.puts("previous job already running")
    else
      Parent.GenServer.start_child(%{
        id: :job,
        start: {Task, :start_link, [&job/0]}
      })
    end

    {:noreply, state}
  end

  def handle_info(unknown_message, state), do: super(unknown_message, state)

  defp job() do
    num = :rand.uniform(2000)
    Process.sleep(num)
    IO.puts(num)
  end
end
```

### Parent.GenServer vs Quantum

`Parent.GenServer` doesn't aim to compete with or replace quantum or similar cron-like libraries. Quantum is a great library which offers many advanced features. Moreover, implementing the scenario above with quantum can be done in a couple lines of code. I've used quantum myself in production, and if you're looking for a quick and a battle-tested solution, quantum is a great choice.

On the upside, `Parent.GenServer` is much simpler to reason about. While quantum involves more complex flow between multiple processes, reasoning about `Parent.GenServer` is as simple as reasoning about any GenServer.

In addition, a `Parent.GenServer` offers a high degree of flexibility. Here are some examples of what's possible with `Parent.GenServer`:

- Start each periodic job in an arbitrary place in the supervision tree (as opposed to using one ticker/scheduler for all jobs).
- Power jobs by behaviours such as GenServer or `gen_statem` (as opposed to always running them in a `Task`).
- Cancel jobs as desired (e.g. stop a job instance if it takes too long).
- Use arbitrary logic in intervals between consecutive job executions (e.g. incremental back-off on consecutive failures).

Personally, I think that `Parent.GenServer` might be a better option in the following conditions:

- The interval is fairly small.
- You don't care about occasional drift.
- You want to run the job locally (i.e. you don't need distributed capabilities).

In my limited experience, most of periodic jobs I wanted to run had these properties, and so parent based periodic execution seems like a compelling choice.

As a more elaborate demo checkout the [Periodic module](https://github.com/sasa1977/parent/blob/master/lib/periodic.ex) which implements a generic periodic runner.

## Cancellation and timeout

In this scenario we have the following needs:

- Start a job on user's request.
- Inform the user about sucess or failure.
- Stop the job if it has been running for too long.
- Stop the job on user's request.

A simple sketch is given in the following code:

```elixir
defmodule Demo.Cancellable do
  use Parent.GenServer

  def start_link(), do: Parent.GenServer.start_link(__MODULE__, nil)

  def stop(pid), do: GenServer.stop(pid)

  @impl GenServer
  def init(_) do
    Parent.GenServer.start_child(%{
      id: :job,
      start: {Task, :start_link, [&job/0]}
    })

    Process.send_after(self(), :timeout, :timer.seconds(1))

    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    IO.puts("timeout")
    {:stop, :timeout, state}
  end

  def handle_info(unknown_message, state), do: super(unknown_message, state)

  @impl Parent.GenServer
  def handle_child_terminated(:job, _meta, _pid, reason, state) do
    if reason == :normal do
      IO.puts("job succeeded")
    else
      IO.puts("job failed")
    end

    {:stop, reason, state}
  end

  defp job() do
    if :rand.uniform(5) == 1, do: raise("error")
    num = :rand.uniform(1500)
    Process.sleep(num)
    IO.puts(num)
  end
end
```

When you invoke `Demo.Cancellable.start_link()`, a job will be started. Depending on chance, the job will be succeed, fail (crash), or timeout. Each outcome is properly handled by its parent, and the failures are propagated further up the supervision tree.

Moreover, you can cancel the job manually:

```
iex> {:ok, pid} = Demo.Cancellable.start_link(); Demo.Cancellable.stop(pid)
```

## Simple queue with limited concurrency

In this demo, we'll implement a job queue. The queue is a parent server which starts each job as a child task. The queue uses limited concurrency, with no more than 10 simultaneous jobs running at any point in time. Here's the full implementation:

```elixir
defmodule Demo.Queue do
  use Parent.GenServer

  def start_link() do
    Parent.GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def add_jobs(count) do
    GenServer.call(__MODULE__, {:add_jobs, count})
  end

  @impl GenServer
  def init(_) do
    {:ok, %{pending: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:add_jobs, count}, _from, state) do
    state = Enum.reduce(1..count, state, &push_item(&2, &1))
    {:reply, :ok, state}
  end

  @impl Parent.GenServer
  def handle_child_terminated(_id, _meta, _pid, reason, state) do
    if reason == :normal do
      IO.puts("job succeeded")
    else
      IO.puts("job failed")
    end

    {:noreply, maybe_start_next_job(state)}
  end

  defp push_item(state, item) do
    state.pending
    |> update_in(&:queue.in(item, &1))
    |> maybe_start_next_job()
  end

  defp maybe_start_next_job(state) do
    with max_jobs = 10,
         true <- Parent.GenServer.num_children() < max_jobs,
         {{:value, _item}, remaining} <- :queue.out(state.pending) do
      start_job()
      maybe_start_next_job(%{state | pending: remaining})
    else
      _ -> state
    end
  end

  defp start_job() do
    Parent.GenServer.start_child(%{
      id: make_ref(),
      start: {Task, :start_link, [&job/0]}
    })
  end

  defp job() do
    num = :rand.uniform(1500)
    Process.sleep(num)
    if :rand.uniform(5) == 1, do: raise("error")
  end
end
```

To use it, start the queue, and add some jobs:

```
Demo.Queue.start_link()
Demo.Queue.add_jobs(100) # enqueue 100 jobs
```

You should see how some jobs succeed, while other fail.

You might wonder how this compares to poolboy and similar pooling libraries. While there's some overlap, I believe that parent-based queue serves different cases. If you need to manage long-running resource oriented servers (such as db connections), you should opt for poolboy. On the other hand, I think that parent is more suitable for one-offs, since it runs every job in a separate process (which can admittedly be obtained with poolboy using max_overflow). In addition, the parent solution gives you a good amount of flexibility, allowing you for example to run jobs of different kinds, or implement more elaborate flow between jobs (e.g. don't start job bar before foo complets successfully, but allow baz to start unconditionally, which is in fact the scenario I've had in practice).

## Final thoughts

I've previously implemented all of the scenarios above using vanilla GenServer, and I find the parent-based code to be much more focused on it's main job (periodic execution, cancellation, queuing).

This is precisely the goal of the parent library. I've seen such scenarios often enough to be annoyed by manual implementation from scratch. Beyond just saving typing and improving the reading experience, I think that the abstraction reduces the potential for accidental bugs. A manual implementation has to keep track of running child processes, worry about `:EXIT` or `:DOWN` messages, and make sure to terminate the child processes before it stops. All of this is automatically taken care of by the `Parent.GenServer`. Finally, compared to high-level out-of-the-box solutions such as quantum and poolboy, parent is less feature rich, but I think it's easier to reason about, and supports a wider set of scenarios.

On the downside, this is in some ways a dangerous behaviour. It should be made clear that parent is not appropriate in all scenarios, and that standard supervision is most often the recommended approach. Since the parent process is not a supervisor, code reloading won't work (though I think we could make it work). That's why I feel that parent is suitable to parent only jobs, i.e. processes which stop in a finite amount of time, and don't serve requests from other processes in the system.
