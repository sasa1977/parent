# 0.11.0

## Breaking changes
- Children are by default permanent, so they are automatically restarted. This also means that `GenServer.handle_child_terminated` won't be invoked. To retain the previous behaviour of your existing parent processes you need to explicitly set the `:restart` option of your children to `:temporary`.
- `handle_child_terminated/5` callback of `Parent.GenServer` is replaced with `handle_child_terminated/2`.
- `Parent.await_child_termination/2` is removed.
- Return type of functions `Parent.children/0`, `Parent.handle_message/1`, `Parent.shutdown_child/1`, `Parent.restart_child/1` has changed. Refer to documentation for details.

## Additions

- Support for automatic restarts of children via the `:restart` option.

# 0.10.0

- **[Deprecation]** - all `Parent.GenServer` functions except for `start_link` have been deprecated. Use equivalent functions from the `Parent` module instead.
- The `Parent` module which provides plumbing for building custom parent processes and behaviours is now included in the public API.

# 0.9.0

- `Parent.GenServer` terminates children synchronously, in the reverse start order. The same change holds for `shutdown_all/1`.

# 0.8.0

## Periodic

- Improved support for custom scheduling via the `:when` option.
- Simplified synchronous testing via `Periodic.sync_tick/2`.

### The `:when` option

The `:when` option assists the implementation of custom schedulers. For example, let's say we want to run a job once a day at midnight. In previous version, the suggested approach was as follows:

```elixir
Periodic.start_link(
  every: :timer.minutes(1),
  run: fn ->
    with %Time{hour: 0, minute: 0} <- Time.utc_now(),
      do: run_job()
  end
)
```

Note that with this approach we're actually starting a new job process every minute, and making a decision in that process. The problem here is that telemetry events and log entries will be emitted once every minute, instead of just once per day, which will lead to a lot of unwanted noise. Consequently, with this approach some parts of `Periodic` (telemetry, logging, handling of overlapping jobs) become useless.

The `:when` option can help us here. Let's see the usage first. The previous example can be rewritten as:

```elixir
Periodic.start_link(
  every: :timer.minutes(1),
  when: fn -> match?(%Time{hour: 0, minute: 0}, Time.utc_now()) end,
  run: &run_job/0
)
```

Unlike a custom check executed in the job, the `:when` function is invoked inside the scheduler process. If the function returns `false`, the job won't be started at all. As a result, all the features of `Periodic`, including telemetry and logging, will work exactly as expected. For example, telemetry events will only be emitted at midnight.

### Synchronous manual ticking

Previously `Periodic.Test` exposed the `tick/1` function which allowed clients to manually tick the scheduler. The problem here was that `tick` would return before the job finished, so client code needed to perform a sequence of steps to test the scheduler:

1. Provide the telemetry id
2. Setup telemetry handler in the test
3. Invoke `tick/1`
4. Invoke `assert_periodic_event(telemetry_id, :finished, %{reason: :normal})` to wait for the job to finish, and assert that it hasn't crashed.

The new `sync_tick` function turns this into a single step:

```elixir
assert Periodic.Test.sync_tick(pid_or_registered_name) == {:ok, :normal}
```

# 0.7.0

## Periodic

- **[Breaking]** The options `:log_level` and `:log_meta` are not supported anymore. Logging is done via telemetry and the provided `Periodic.Logger`.
- **[Breaking]** The value `:infinity` isn't accepted for the options `:every` and `:initial_delay` anynmore. Instead, if you want to avoid running the job in test environment, set the `:mode` option to `:manual`.
- Telemetry events are now emitted. The new module `Periodic.Logger` can be used to log these events.
- Added `Periodic.Test` to support deterministic testing of periodic jobs.
- Scheduler process can be registered via the `:name` option.
- Default job shutdown is changed to 5 seconds (from `:brutal_kill`), and can now be configured via the `:job_shutdown` option. This allows polite termination (the parent of the scheduler process will wait until the job is done).
- Scheduling is now based on absolute monotonic time, which reduces the chance of clock skew in regular delay mode.
- Documentation is thoroughly reworked. Check it out [here](https://hexdocs.pm/parent/Periodic.html#content).

# 0.6.0

- The `:overlap?` option in `Periodic` is deprecated. Use `:on_overlap` instead.
- Added support for termination of previous job instances in `Periodic` via the `:on_overlap` option.
- Added support for the shifted delay mode in `Periodic` via the `:delay_mode` option.

# 0.5.1

- support handle_continue on Elixir 1.7.x or greater

# 0.5.0

- add supervisor compliance to support hot code reloads

# 0.4.1

- Fixed `Periodic` typespec.

# 0.4.0

- Added support for `:initial_delay` in `Periodic`

# 0.3.0

- Added `Parent.GenServer.await_child_termination/2`

# 0.2.0

- Added the support for child timeout. See the "Timeout" section in `Parent.GenServer`.

# 0.1.1

- Bugfix: termination of all children would crash if a timeout occurs while terminating a child

# 0.1.0

- First version
