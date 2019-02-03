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
