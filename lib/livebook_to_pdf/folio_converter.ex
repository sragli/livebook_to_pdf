defmodule LivebookToPdf.FolioConverter do
  @moduledoc """
  Converts parsed Livebook content blocks into a `Folio.Document` for PDF generation.

  Code cells are excluded. Markdown blocks pass through unchanged. Rich output
  blocks (HTML tables, plain text results) are converted to Markdown equivalents.

  VegaLite chart specs are rendered to SVG in-process via the `vega_lite_convert`
  hex package (a Rustler NIF wrapping the vl-convert Rust library). No external
  tools need to be installed — all rendering happens inside the BEAM.
  """

  @doc """
  Builds a `Folio.Document` from parsed blocks, styled for a scientific article.

  VegaLite output blocks are rendered to SVG in-process via the
  `vega_lite_convert` NIF and attached to the document.

  Options:
    - `:title`  – override the document title (replaces the first H1)
    - `:author` – author name inserted beneath the title
    - `:date`   – date string inserted beneath the title
  """
  @spec build_document([map()], keyword()) :: {:ok, Folio.Document.t()} | {:error, term()}
  def build_document(blocks, opts \\ []) do
    {markdown, images} = render_blocks(blocks)
    markdown = inject_metadata(markdown, opts)

    doc =
      blocks
      |> then(fn _ ->
        Folio.Document.new()
        |> Folio.Document.add_style(scientific_styles())
      end)
      |> attach_images(images)
      |> Folio.Document.add_content(markdown)

    {:ok, doc}
  rescue
    e -> {:error, e}
  end

  @doc """
  Converts parsed blocks to a clean Markdown string, excluding code cells.

  VegaLite outputs are represented as placeholder notes (no external process is
  invoked). Use `build_document/2` to get actual chart images.
  """
  @spec to_markdown([map()], keyword()) :: String.t()
  def to_markdown(blocks, opts \\ []) do
    body =
      blocks
      |> Enum.filter(&(&1.type != :code))
      |> Enum.map_join("\n\n", &block_to_markdown_simple/1)
      |> String.trim()

    inject_metadata(body, opts)
  end

  # ── Full rendering (with chart PNG generation) ───────────────────────────────

  # Returns {markdown_string, [{filename, png_bytes}]}
  defp render_blocks(blocks) do
    {parts, images, _idx} =
      blocks
      |> Enum.filter(&(&1.type != :code))
      |> Enum.reduce({[], [], 0}, fn block, {parts, images, idx} ->
        case render_block(block, idx) do
          {:chart, md_snippet, filename, png_bytes} ->
            {[md_snippet | parts], [{filename, png_bytes} | images], idx + 1}

          md_snippet ->
            {[md_snippet | parts], images, idx}
        end
      end)

    markdown =
      parts
      |> Enum.reverse()
      |> Enum.join("\n\n")
      |> String.trim()

    {markdown, Enum.reverse(images)}
  end

  defp render_block(%{type: :markdown, content: content}, _idx), do: content

  defp render_block(%{type: :output, language: lang, content: content}, idx) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        ""

      lang in ["html", "text/html"] ->
        html_output_to_markdown(trimmed)

      lang in ["vega-lite", "vega_lite"] ->
        render_vegalite(trimmed, idx)

      true ->
        "> #{String.replace(trimmed, "\n", "\n> ")}"
    end
  end

  defp render_block(_, _idx), do: ""

  # ── Simple rendering (no chart images, for to_markdown/2) ───────────────────

  defp block_to_markdown_simple(%{type: :markdown, content: content}), do: content

  defp block_to_markdown_simple(%{type: :output, language: lang, content: content}) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        ""

      lang in ["html", "text/html"] ->
        html_output_to_markdown(trimmed)

      lang in ["vega-lite", "vega_lite"] ->
        "> _[VegaLite chart — see PDF output for rendered chart]_"

      true ->
        "> #{String.replace(trimmed, "\n", "\n> ")}"
    end
  end

  defp block_to_markdown_simple(_), do: ""

  # ── VegaLite → SVG rendering via vega_lite_convert NIF ───────────────────────
  #
  # VegaLite.Convert.to_svg/1 calls into a bundled Rust NIF (vl-convert-rs) —
  # no external tools or manual installs required.

  defp render_vegalite(spec_json, idx) do
    filename = "chart_#{idx}.svg"

    vl = VegaLite.from_json(spec_json)
    svg = VegaLite.Convert.to_svg(vl)
    {:chart, "![Chart #{idx + 1}](#{filename})", filename, svg}
  rescue
    e ->
      "> _[Chart #{idx + 1} — VegaLite rendering failed: #{Exception.message(e)}]_"
  end

  defp attach_images(doc, images) do
    Enum.reduce(images, doc, fn {filename, bytes}, acc ->
      Folio.Document.attach_file(acc, filename, bytes)
    end)
  end

  # ── HTML → Markdown ──────────────────────────────────────────────────────────

  defp html_output_to_markdown(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        cond do
          Floki.find(tree, "table") != [] ->
            tree |> Floki.find("table") |> List.first() |> html_table_to_markdown()

          true ->
            text = Floki.text(tree) |> String.trim()
            if text != "", do: "> #{String.replace(text, "\n", "\n> ")}", else: ""
        end

      _ ->
        ""
    end
  end

  defp html_table_to_markdown(nil), do: ""

  defp html_table_to_markdown(table) do
    headers =
      table
      |> Floki.find("thead th, thead td")
      |> Enum.map(&Floki.text/1)

    rows =
      table
      |> Floki.find("tbody tr")
      |> Enum.map(fn row ->
        row |> Floki.find("td, th") |> Enum.map(&Floki.text/1)
      end)

    col_count = max(length(headers), rows |> List.first([]) |> length())

    if col_count == 0 do
      ""
    else
      header_row =
        if headers != [] do
          "| #{Enum.join(headers, " | ")} |"
        else
          "| #{List.duplicate("", col_count) |> Enum.join(" | ")} |"
        end

      separator = "| #{List.duplicate("---", col_count) |> Enum.join(" | ")} |"

      body_rows =
        Enum.map_join(rows, "\n", fn row ->
          padded = row ++ List.duplicate("", max(0, col_count - length(row)))
          "| #{padded |> Enum.take(col_count) |> Enum.join(" | ")} |"
        end)

      [header_row, separator, body_rows]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  # ── Metadata injection ────────────────────────────────────────────────────────

  defp inject_metadata(body, opts) do
    body = if opts[:title], do: replace_or_prepend_h1(body, opts[:title]), else: body
    meta = format_metadata(opts[:author], opts[:date])
    if meta, do: insert_after_first_heading(body, meta), else: body
  end

  defp replace_or_prepend_h1(body, title) do
    if Regex.match?(~r/^# .+/m, body) do
      Regex.replace(~r/^# .+/m, body, "# #{title}", global: false)
    else
      "# #{title}\n\n#{body}"
    end
  end

  defp format_metadata(nil, nil), do: nil
  defp format_metadata(author, nil), do: "_#{author}_"
  defp format_metadata(nil, date), do: "_#{date}_"
  defp format_metadata(author, date), do: "_#{author} · #{date}_"

  defp insert_after_first_heading(body, meta) do
    lines = String.split(body, "\n")

    case Enum.find_index(lines, &Regex.match?(~r/^#+\s/, &1)) do
      nil ->
        "#{meta}\n\n#{body}"

      idx ->
        {before, [heading | rest]} = Enum.split(lines, idx)
        (before ++ [heading, meta, ""] ++ rest) |> Enum.join("\n")
    end
  end

  # ── Scientific article styles ─────────────────────────────────────────────────

  # A4 paper (595 × 842 pt), comfortable academic margins (~2.5 cm top/bottom,
  # ~3 cm sides), 11 pt body text, justified paragraphs, numbered sections, and
  # page numbers.
  defp scientific_styles do
    [
      Folio.Styles.page_size(width: 595, height: 842),
      Folio.Styles.page_margin(top: 71, bottom: 71, left: 85, right: 85),
      Folio.Styles.font_size(11),
      Folio.Styles.par_justify(true),
      Folio.Styles.heading_numbering("1.1"),
      Folio.Styles.page_numbering("1"),
      Folio.Styles.hyphenate(true)
    ]
  end
end
