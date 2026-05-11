defmodule LivebookToPdf.MixProject do
  use Mix.Project

  def project do
    [
      app: :livebook_to_pdf,
      version: "0.1.0",
      elixir: "~> 1.17",
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
      {:folio, "~> 0.2.3"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.36"},
      {:vega_lite, "~> 0.1"},
      {:vega_lite_convert, "~> 1.0"}
    ]
  end
end
