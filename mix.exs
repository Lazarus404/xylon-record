defmodule XylonRecord.MixProject do
  use Mix.Project

  def project do
    [
      app: :xylon_record,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Xylon room recording tap: Janus .mjr (MJR00002) stems.",
      source_url: "https://github.com/Lazarus404/xylon_record",
      docs: [
        extras: ["README.md"],
        main: "readme"
      ],
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      xylon_dep(),
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp xylon_dep do
    if System.get_env("XTURN_LOCAL_DEPS") == "1" do
      {:xylon, path: Path.expand("../xylon", __DIR__), override: true}
    else
      {:xylon, git: "https://github.com/Lazarus404/xylon.git", override: true}
    end
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Lazarus404/xylon_record"},
      files: ~w(lib mix.exs README.md LICENSE .gitignore)
    ]
  end
end
