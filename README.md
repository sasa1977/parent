# Parent

[![hex.pm](https://img.shields.io/hexpm/v/parent.svg?style=flat-square)](https://hex.pm/packages/parent)
[![hexdocs.pm](https://img.shields.io/badge/docs-latest-green.svg?style=flat-square)](https://hexdocs.pm/parent/)
[![Build Status](https://travis-ci.org/sasa1977/parent.svg?branch=master)](https://travis-ci.org/sasa1977/parent)

Support for custom parenting of processes. See [docs](https://hexdocs.pm/parent/) for reference.

Parent is a toolkit for building processes which parent other children and manage their life cycles. The library provides features similar to `Supervisor`, including the support for automatic restarts and failure escalation (maximum restart intensity). Some additional benefits that Parent brings, when compared to `Supervisor` are:

- Exposed lower level plumbing modules, such as `Parent.GenServer` and `Parent`, which can be used to build custom parent processes (i.e. supervisors with custom logic).
- No supervision strategies (one_for_one, rest_for_one, etc). Instead, Parent uses bindings and shutdown groups to achieve the similar behaviour. This can result in flatter and simpler supervision trees.
- Basic registry-like capabilities for simple children discovery.

## Examples

### Basic supervisor

```elixir
Parent.Supervisor.start_link(
  # child spec is a superset of supervisor child specification
  child_specs,

  # parent options, note that there's no `:strategy`
  max_restarts: 3,
  max_seconds: 5,

  # std. Supervisor/GenServer options
  name: __MODULE__
)
```

### Per-child max restart frequency

```elixir
Parent.Supervisor.start_link(
  [
    Parent.child_spec(Child1, max_restarts: 10, max_seconds: 10),
    Parent.child_spec(Child2, max_restarts: 3, max_seconds: 5)
  ],

  # Per-parent max restart frequency can be disabled, or a parent-wide limit can be used. In the
  # former case make sure that this limit is higher than the limit of any child.
  max_restarts: :infinity
)
```

### Binding lifecycles

```elixir
  Parent.Supervisor.start_link(
    [
      Parent.child_spec(Child1),
      Parent.child_spec(Child2, bind_to: [Child1]),
      Parent.child_spec(Child3, bind_to: [Child1]),
      Parent.child_spec(Child4, shutdown_group: :children4_to_6),
      Parent.child_spec(Child5, shutdown_group: :children4_to_6),
      Parent.child_spec(Child6, shutdown_group: :children4_to_6),
      Parent.child_spec(Child7, bind_to: [Child1]),
    ]
  )
```

- if `Child1` is restarted, `Child2`, `Child3`, and `Child7` will be restarted too
- if `Child2`, `Child3`, or `Child7` is restarted, nothing else is restarted
- if any of `Child4`, `Child5`, or `Child6` is restarted, all other processes from the shutdown group are restarted too

### Pausing and resuming a part of the system

```elixir
# stops child1 and all children depending on it
stopped_children = Parent.Client.shutdown_child(some_parent, :child1)

# ...

# returns all stopped children back to the parent
Parent.Client.return_children(some_parent, stopped_children)
```

### Dynamic supervisor with anonymous children

```elixir
Parent.Supervisor.start_link([])

{:ok, pid1} = Parent.Client.start_child(MySup, Parent.child_spec(Child, id: nil))
{:ok, pid2} = Parent.Client.start_child(MySup, Parent.child_spec(Child, id: nil))
# ...

Parent.Client.shutdown_child(MySup, pid1)
Parent.Client.restart_child(MySup, pid2)
```

### Dynamic supervisor with child discovery

```elixir
Parent.Supervisor.start_link([], name: MySup)

# meta is an optional value associated with the child
Parent.Client.start_child(MySup, Parent.child_spec(Child, id: id1, meta: some_meta))
Parent.Client.start_child(MySup, Parent.child_spec(Child, id: id2, meta: another_meta))
# ...

# synchronous calls into the parent process
pid = Parent.Client.child_pid(MySup, id1)
meta = Parent.Client.child_meta(MySub, id1)
all_children = Parent.Client.children(MySup)
```

Optional ETS-powered registry:

```elixir
Parent.Supervisor.start_link([], registry?: true)

# start some children

# ETS lookup, no call into parent involved
Parent.Client.child_pid(my_sup, id1)
Parent.Client.children(my_sup)
```

### Module-based supervisor

```elixir
defmodule MySup do
  use Parent.GenServer

  def start_link(init_arg),
    do: Parent.GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl GenServer
  def init(_init_arg) do
    Parent.start_all_children!(children)
    {:ok, initial_state}
  end
end
```

### Restarting with a delay

```elixir
defmodule MySup do
  use Parent.GenServer

  def start_link(init_arg),
    do: Parent.GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl GenServer
  def init(_init_arg) do
    # Make sure that children are temporary b/c otherwise `handle_stopped_children/2` won't be invoked.
    Parent.start_all_children!(children)
    {:ok, initial_state}
  end

  @impl Parent.GenServer
  def handle_stopped_children(stopped_children, state) do
    # invoked when a child stops and is not restarted
    Process.send_after(self, {:restart, stopped_children}, delay)
    {:noreply, state}
  end

  def handle_info({:restart, stopped_children}, state) do
    # Returns the child to the parent preserving its place according to startup order and bumping
    # its restart count. This is basically a manual restart.
    Parent.return_children(stopped_children, include_temporary?: true)
    {:noreply, state}
  end
end
```

### Starting additional children after a child stops

```elixir
defmodule MySup do
  use Parent.GenServer

  def start_link(init_arg),
    do: Parent.GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl GenServer
  def init(_init_arg) do
    Parent.start_child(first_child_spec)
    {:ok, initial_state}
  end

  @impl Parent.GenServer
  def handle_stopped_children(%{child1: info}, state) do
    Parent.start_child(other_children)
    {:noreply, state}
  end

  def handle_stopped_children(_other, state), do: {:noreply, state}
end
```

### Building a custom parent process or behaviour from scratch

```elixir
defp init_process do
  Parent.initialize(parent_opts)
  start_some_children()
  loop()
end

defp loop() do
  receive do
    msg ->
      case Parent.handle_message(msg) do
        # parent handled the message
        :ignore -> loop()

        # parent handled the message and returned some useful information
        {:stopped_children, stopped_children} -> handle_stopped_children(stopped_children)

        # not a parent message
        nil -> custom_handle_message(msg)
      end
  end
end
```

## Status

This library has seen production usage in a couple of different projects. However, features such as automatic restarts and ETS registry are pretty fresh (aded in late 2020) and so they haven't seen any serious production testing yet.

Based on a very quick & shallow test, Parent is about 3x slower and consumes about 2x more memory than DynamicSupervisor.

The API is prone to significant changes.

Compared to supervisor crash reports, the error logging is very basic and probably not sufficient.

## License

[MIT](./LICENSE)
