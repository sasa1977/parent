defmodule Parent.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    Parent.Supervisor.start_link(
      [Parent.MetaRegistry],
      name: __MODULE__
    )
  end
end
