defmodule LivebookToPdf do
  @moduledoc """
  Converts Livebook (`.livemd`) notebooks to publication-ready PDFs in a
  scientific article format, powered by [Folio](https://hexdocs.pm/folio) and
  the Typst layout engine.

  ## What is included

  - Narrative text (headings, paragraphs, lists, blockquotes)
  - Markdown tables
  - Inline and display math (`$...$` / `$$...$$`)
  - Images referenced in the notebook
  - Rich cell outputs: HTML tables (e.g. from `Kino.DataTable`) and plain-text
    expression results

  ## What is excluded

  - Elixir code cells (the source code itself)
  - Vega-Lite / interactive chart specs (a placeholder note is emitted)

  ## Usage

      # Convert a notebook and save the PDF next to it
      {:ok, pdf_path} = LivebookToPdf.convert("report.livemd")

      # Specify output path and author
      {:ok, pdf_path} = LivebookToPdf.convert("report.livemd",
        output: "~/Desktop/report.pdf",
        author: "Jane Doe"
      )

      # Only retrieve the cleaned Markdown string (no PDF compilation)
      {:ok, markdown} = LivebookToPdf.to_markdown("report.livemd")
  """

  alias LivebookToPdf.{Parser, FolioConverter}

  @doc """
  Converts a Livebook file at `input_path` to a PDF.

  Returns `{:ok, pdf_path}` on success or `{:error, reason}` on failure.

  ## Options

  | Key       | Description                                       | Default                  |
  |-----------|---------------------------------------------------|--------------------------|
  | `:output` | Output PDF file path                              | same dir as input        |
  | `:title`  | Override the document title                       | first H1 in the notebook |
  | `:author` | Author name inserted beneath the title            | none                     |
  | `:date`   | Date string inserted beneath the title            | none                     |
  """
  @spec convert(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def convert(input_path, opts \\ []) do
    output_path =
      opts[:output] ||
        Path.join(Path.dirname(input_path), Path.basename(input_path, ".livemd") <> ".pdf")

    with {:ok, content} <- File.read(input_path),
         {:ok, blocks} <- Parser.parse(content),
         {:ok, doc} <- FolioConverter.build_document(blocks, opts),
         {:ok, pdf_bytes} <- Folio.to_pdf(doc),
         :ok <- File.write(output_path, pdf_bytes) do
      {:ok, output_path}
    end
  end

  @doc """
  Parses a Livebook file and returns the cleaned Markdown string that would be
  passed to Folio, without compiling to PDF.

  Useful for inspecting or post-processing the intermediate representation.
  """
  @spec to_markdown(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_markdown(input_path, opts \\ []) do
    with {:ok, content} <- File.read(input_path),
         {:ok, blocks} <- Parser.parse(content) do
      {:ok, FolioConverter.to_markdown(blocks, opts)}
    end
  end

  @doc """
  Parses a Livebook file and returns the raw list of content blocks.

  Each block is a map with `:type`, `:language`, and `:content` keys.
  Block types: `:markdown`, `:code`, `:output`.
  """
  @spec parse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(input_path) do
    with {:ok, content} <- File.read(input_path) do
      Parser.parse(content)
    end
  end
end
