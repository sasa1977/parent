{:ok, parent} = Parent.Supervisor.start_link([])

:timer.tc(fn ->
  Enum.each(
    1..100_000,
    fn _i ->
      Parent.Client.start_child(
        parent,
        %{start: {Agent, :start_link, [fn -> :ok end]}, restart: :temporary}
      )
    end
  )
end)
|> elem(0)
|> Kernel.div(1000)
|> IO.inspect()

IO.inspect(Process.info(parent, :memory))

{:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

:timer.tc(fn ->
  Enum.each(
    1..100_000,
    fn i ->
      DynamicSupervisor.start_child(
        sup,
        %{id: i, start: {Agent, :start_link, [fn -> :ok end]}, restart: :temporary}
      )
    end
  )
end)
|> elem(0)
|> Kernel.div(1000)
|> IO.inspect()

IO.inspect(Process.info(sup, :memory))
