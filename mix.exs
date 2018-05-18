defmodule Parent.MixProject do
  use Mix.Project

  def project do
    [
      app: :parent,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_deps: :transitive]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 0.4.0", only: [:dev, :test]},
      {:dialyxir, "~> 0.5.0", runtime: false, only: [:dev, :test]},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
