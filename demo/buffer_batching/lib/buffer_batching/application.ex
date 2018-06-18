defmodule BufferBatching.Application do
  use Application

  def start(_type, _args) do
    children = [
      BufferBatching.Consumer,
      BufferBatching.Producer
    ]

    opts = [strategy: :rest_for_one, name: BufferBatching.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
