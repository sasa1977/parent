defmodule Parent.MixProject do
  use Mix.Project

  def project do
    [
      app: :parent,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 0.4.0"}
    ]
  end
end
