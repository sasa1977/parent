use Mix.Config

config :logger, :console,
  format: "$metadata[$level] $message\n",
  metadata: []
