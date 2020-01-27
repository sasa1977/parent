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
