defmodule BufferBatching.MixProject do
  use Mix.Project

  def project do
    [
      app: :buffer_batching,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {BufferBatching.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:parent, "~> 0.3.0"}
    ]
  end
end
