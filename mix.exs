defmodule Parent.MixProject do
  use Mix.Project

  @version "0.12.0"

  def project do
    [
      app: :parent,
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_deps: :transitive, plt_add_apps: [:ex_unit]],
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Parent.Application, []}
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 0.5", runtime: false, only: [:dev, :test]},
      {:ex_doc, "~> #{ex_doc_version()}", only: :dev, runtime: false},
      {:mox, "~> 0.5.0", only: :test},
      {:telemetry, "~> 0.4 or ~> 1.0"}
    ]
  end

  defp ex_doc_version() do
    if Version.compare(System.version(), "1.7.0") == :lt, do: "0.18.0", else: "0.19"
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs() do
    [
      extras: ["README.md"],
      main: "readme",
      source_url: "https://github.com/sasa1977/parent/",
      source_ref: @version,
      groups_for_modules: [
        Core: [Parent, Parent.Client],
        Behaviours: [Parent.GenServer, Parent.Supervisor],
        "Periodic job execution": ~r/Periodic(\..+)?/
      ]
    ]
  end

  defp package() do
    [
      description: "Custom parenting of processes.",
      maintainers: ["Saša Jurić"],
      licenses: ["MIT"],
      links: %{
        "Github" => "https://github.com/sasa1977/parent",
        "Changelog" =>
          "https://github.com/sasa1977/parent/blob/#{@version}/CHANGELOG.md##{
            String.replace(@version, ".", "")
          }"
      }
    ]
  end
end
