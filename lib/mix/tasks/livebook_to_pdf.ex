defmodule Mix.Tasks.LivebookToPdf do
  use Mix.Task

  @shortdoc "Convert a Livebook (.livemd) file to a PDF"

  @moduledoc """
  Converts a Livebook notebook (`.livemd`) to a publication-ready PDF in
  scientific article format, powered by Folio and the Typst layout engine.

      mix livebook_to_pdf INPUT [OUTPUT] [OPTIONS]

  ## Arguments

    * `INPUT`  – path to the `.livemd` file (required)
    * `OUTPUT` – path for the output PDF file (optional; defaults to the same
                 directory as the input with a `.pdf` extension)

  ## Options

    * `--author NAME`      – set the document author
    * `--title TITLE`      – override the document title
    * `--date DATE`        – set the date string
    * `--markdown-only`    – only generate the cleaned `.md` file, do not compile to PDF

  ## Examples

      mix livebook_to_pdf report.livemd
      mix livebook_to_pdf report.livemd ~/Desktop/report.pdf --author "Jane Doe"
      mix livebook_to_pdf report.livemd --markdown-only
  """

  @switches [
    author: :string,
    title: :string,
    date: :string,
    markdown_only: :boolean
  ]

  @aliases [
    a: :author,
    t: :title
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    case args do
      [] ->
        Mix.raise("Usage: mix livebook_to_pdf INPUT [OUTPUT] [OPTIONS]")

      [input | rest] ->
        output = List.first(rest)

        if opts[:markdown_only] do
          run_markdown_only(input, output, opts)
        else
          run_convert(input, output, opts)
        end
    end
  end

  defp run_convert(input, output, opts) do
    convert_opts = build_opts(opts, output)

    Mix.shell().info("Converting #{input} …")

    case LivebookToPdf.convert(input, convert_opts) do
      {:ok, pdf_path} ->
        Mix.shell().info("PDF written to #{pdf_path}")

      {:error, errors} when is_list(errors) ->
        messages = Enum.map_join(errors, "\n", &Exception.message/1)
        Mix.raise("PDF compilation failed:\n\n#{messages}")

      {:error, reason} ->
        Mix.raise("Conversion failed: #{inspect(reason)}")
    end
  end

  defp run_markdown_only(input, output, opts) do
    md_path =
      output ||
        Path.join(Path.dirname(input), Path.basename(input, ".livemd") <> ".md")

    convert_opts = build_opts(opts, nil)

    Mix.shell().info("Generating Markdown for #{input} …")

    case LivebookToPdf.to_markdown(input, convert_opts) do
      {:ok, markdown} ->
        File.write!(md_path, markdown)
        Mix.shell().info("Markdown written to #{md_path}")

      {:error, reason} ->
        Mix.raise("Markdown generation failed: #{inspect(reason)}")
    end
  end

  defp build_opts(opts, output) do
    base = Keyword.take(opts, [:author, :title, :date])
    if output, do: Keyword.put(base, :output, output), else: base
  end
end
