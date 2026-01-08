defmodule ExRTMP.MixProject do
  use Mix.Project

  @version "0.3.1"
  @github_url "https://github.com/elixir-streaming/ex_rtmp"

  def project do
    [
      app: :ex_rtmp,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # hex
      description: "RTMP server and client implementation in Elixir",
      package: package(),

      # docs
      name: "RTMP Server and Client",
      source_url: @github_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_flv, "~> 0.4.0"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:media_codecs, "~> 0.8.0", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Billal Ghilas"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "LICENSE"
      ],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        ExRTMP.Server,
        ExRTMP.Message,
        ExRTMP.Message.Command
      ],
      groups_for_modules: [
        Core: [
          "ExRTMP",
          ~r/^ExRTMP\.Client($|\.)/,
          ~r/^ExRTMP\.Server($|\.)/,
          "ExRTMP.Chunk",
          "ExRTMP.Message",
          "ExRTMP.AMF0"
        ],
        Messages: [
          ~r/^ExRTMP\.Message($|\.)/
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
