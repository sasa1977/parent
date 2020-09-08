defmodule Parent.Supervisor do
  @moduledoc """
  Supervisor of child processes.

  This module works similarly to callbackless supervisors started with `Supervisor.start_link/2`.
  To start a supervisor and some children you can do the following:

      Parent.Supervisor.start_link([
        child_spec1,
        child_spec2,
        # ...
      ])

  To install a parent supervisor in the supervision tree you can provide child specification in the
  shape of `{Parent.Supervisor, {children, parent_options}}`.

  To build a dedicate supervisor module you can do:

      defmodule MySupervisor do
        use Parent.Supervisor

        def start_link(children, options),
          do: Parent.Supervisor.start_link(children, options)

        # ...
      end

  And now, you can install this supervisor in the supervision tree by passing
  `{MySupervisor, {child_specs, parent_options}}` as the child specification to the parent.

  You can interact with the running supervisor using functions from the `Parent.Client` module.
  Refer to the `Parent` module for detailed explanation of child specifications, parent options,
  and behaviour of parent processes.

  In case you need more flexibility, take a look `Parent.GenServer`.
  """
  use Parent.GenServer

  @doc """
  Starts the parent process.

  This function returns only after all the children have been started. If a child fails to start,
  the parent process will terminate all successfully started children, and then itself.
  """
  @spec start_link([Parent.start_spec()], Parent.GenServer.options()) :: GenServer.on_start()
  def start_link(children, options \\ []),
    do: Parent.GenServer.start_link(__MODULE__, children, options)

  @impl GenServer
  def init(children) do
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @spec child_spec({[Parent.start_spec()], Parent.GenServer.options()}) :: Parent.child_spec()
  def child_spec({children, options}) do
    [start: {__MODULE__, :start_link, [children, options]}]
    |> Parent.parent_spec()
    |> Parent.child_spec(id: Keyword.get(options, :name, __MODULE__))
  end

  @doc false
  defmacro __using__(_) do
    quote do
      @spec child_spec({[Parent.start_spec()], Parent.GenServer.options()} | []) ::
              Supervisor.child_spec()
      def child_spec([]), do: child_spec({[], []})

      def child_spec({children, options} = args) do
        [start: {__MODULE__, :start_link, [children, options]}]
        |> Parent.parent_spec()
        |> Parent.child_spec(id: Keyword.get(options, :name, __MODULE__))
      end
    end
  end
end
