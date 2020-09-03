defmodule Parent.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(
      [Parent.MetaRegistry],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
