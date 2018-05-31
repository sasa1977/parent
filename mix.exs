defmodule Parent.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :parent,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_deps: :transitive],
      docs: docs(),
      package: package()
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

  defp docs() do
    [
      extras: ["RATIONALE.md"],
      main: "Parent.GenServer",
      source_url: "https://github.com/sasa1977/parent/",
      source_ref: @version
    ]
  end

  defp package() do
    [
      description: "Custom parenting of processes.",
      maintainers: ["Saša Jurić"],
      licenses: ["MIT"],
      links: %{
        "Github" => "https://github.com/sasa1977/parent",
        "Docs" => "http://hexdocs.pm/parent"
      }
    ]
  end
end
