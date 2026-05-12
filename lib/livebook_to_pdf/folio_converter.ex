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
    - `:title`  - override the document title (replaces the first H1)
    - `:author` - author name inserted beneath the title
    - `:date`   - date string inserted beneath the title
  """
  @spec build_document([map()], keyword()) :: {:ok, Folio.Document.t()} | {:error, term()}
  def build_document(blocks, opts \\ []) do
    {markdown, images} = render_blocks(blocks)
    markdown = inject_metadata(markdown, opts)
    nodes = markdown |> preprocess_math() |> Folio.parse_markdown!()

    doc =
      Folio.Document.new()
      |> Folio.Document.add_style(scientific_styles())
      |> attach_images(images)
      |> Folio.Document.add_content(nodes)

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
      # Replace only the first H1 heading by splitting on the first match.
      [before | rest] = Regex.split(~r/^# .+/m, body, parts: 2)
      before <> "# #{title}" <> Enum.join(rest)
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
  # ~3 cm sides), 11 pt body text, justified paragraphs, and page numbers.
  # ── LaTeX → Typst math preprocessing ──────────────────────────────────────
  #
  # Livebook uses KaTeX (LaTeX) syntax inside $…$ and $$…$$ regions.
  # Folio/Typst uses its own math syntax, so we convert the most common LaTeX
  # constructs before handing the markdown to Folio.parse_markdown!.

  defp preprocess_math(markdown) do
    step1 =
      Regex.replace(~r/\$\$(?s)(.*?)\$\$/, markdown, fn _, inner ->
        "$$#{latex_to_typst(inner)}$$"
      end)

    Regex.replace(~r/\$([^$\n]+)\$/, step1, fn _, inner ->
      "$#{latex_to_typst(inner)}$"
    end)
  end

  defp latex_to_typst(math) do
    # Regex.replace(regex, subject, replacement) — helpers keep the pipeline readable.
    r = fn subject, regex, replacement -> Regex.replace(regex, subject, replacement) end

    math
    # ── Literal braces \{ \} – protect before bare-brace substitution ─────────
    # Replace \{ / \} with private-use placeholders so they survive the
    # String.replace("{" → "(") step and are restored as Typst math braces.
    |> String.replace("\\{", "\u{E000}")
    |> String.replace("\\}", "\u{E001}")
    # ── \operatorname(*){…} → upright text ────────────────────────────────────
    |> r.(~r/\\operatorname\*?\{([^{}]*)\}/, fn _, name ->
      clean = String.replace(name, "\\,", " ") |> String.trim()
      "op(\"#{clean}\")"
    end)
    # ── Two-argument commands ──────────────────────────────────────────────────
    |> r.(~r/\\(?:t|d)?frac\{([^{}]*)\}\{([^{}]*)\}/, fn _, a, b ->
      "frac(#{a}, #{b})"
    end)
    |> r.(~r/\\binom\{([^{}]*)\}\{([^{}]*)\}/, fn _, a, b ->
      "binom(#{a}, #{b})"
    end)
    # ── \sqrt with optional root index ────────────────────────────────────────
    |> r.(~r/\\sqrt\[([^\]]+)\]\{([^{}]*)\}/, fn _, n, x ->
      "root(#{n}, #{x})"
    end)
    |> r.(~r/\\sqrt\{([^{}]*)\}/, fn _, x -> "sqrt(#{x})" end)
    # ── One-argument font/style commands ──────────────────────────────────────
    |> r.(~r/\\text\{([^{}]*)\}/, fn _, t -> "\"#{t}\"" end)
    |> r.(~r/\\mbox\{([^{}]*)\}/, fn _, t -> "\"#{t}\"" end)
    |> r.(~r/\\mathbf\{([^{}]*)\}/, fn _, x -> "bold(#{x})" end)
    |> r.(~r/\\(?:boldsymbol|bm)\{([^{}]*)\}/, fn _, x -> "bold(#{x})" end)
    |> r.(~r/\\mathit\{([^{}]*)\}/, fn _, x -> "italic(#{x})" end)
    |> r.(~r/\\mathrm\{([^{}]*)\}/, fn _, x -> "upright(#{x})" end)
    |> r.(~r/\\mathcal\{([^{}]*)\}/, fn _, x -> "cal(#{x})" end)
    |> r.(~r/\\mathbb\{([^{}]*)\}/, fn _, x -> "bb(#{x})" end)
    |> r.(~r/\\mathfrak\{([^{}]*)\}/, fn _, x -> "frak(#{x})" end)
    # ── Accents / decorations ──────────────────────────────────────────────────
    |> r.(~r/\\(?:wide)?hat\{([^{}]*)\}/, fn _, x -> "hat(#{x})" end)
    |> r.(~r/\\(?:wide)?tilde\{([^{}]*)\}/, fn _, x -> "tilde(#{x})" end)
    |> r.(~r/\\vec\{([^{}]*)\}/, fn _, x -> "arrow(#{x})" end)
    |> r.(~r/\\(?:bar|overline)\{([^{}]*)\}/, fn _, x -> "overline(#{x})" end)
    |> r.(~r/\\underline\{([^{}]*)\}/, fn _, x -> "underline(#{x})" end)
    |> r.(~r/\\ddot\{([^{}]*)\}/, fn _, x -> "dot.double(#{x})" end)
    |> r.(~r/\\dot\{([^{}]*)\}/, fn _, x -> "dot(#{x})" end)
    |> r.(~r/\\overbrace\{([^{}]*)\}/, fn _, x -> "overbrace(#{x})" end)
    |> r.(~r/\\underbrace\{([^{}]*)\}/, fn _, x -> "underbrace(#{x})" end)
    # ── \left / \right size hints → strip ────────────────────────────────────
    |> r.(~r/\\left\s*\(/, "(")
    |> r.(~r/\\right\s*\)/, ")")
    |> r.(~r/\\left\s*\[/, "[")
    |> r.(~r/\\right\s*\]/, "]")
    |> r.(~r/\\left\s*\\?\{/, "(")
    |> r.(~r/\\right\s*\\?\}/, ")")
    |> r.(~r/\\left\s*\|/, "|")
    |> r.(~r/\\right\s*\|/, "|")
    |> r.(~r/\\left\s*\./, "")
    |> r.(~r/\\right\s*\./, "")
    # ── Subscripts / superscripts: _{…} → _(…), ^{…} → ^(…) ─────────────────
    |> r.(~r/_\{([^{}]*)\}/, fn _, c -> "_(#{c})" end)
    |> r.(~r/\^\{([^{}]*)\}/, fn _, c -> "^(#{c})" end)
    # ── Remaining bare braces (general grouping) → parens ────────────────────
    |> String.replace("{", "(")
    |> String.replace("}", ")")
    # ── Restore literal math braces from placeholders ─────────────────────────
    |> String.replace("\u{E000}", "{")
    |> String.replace("\u{E001}", "}")
    # ── Named command substitutions ───────────────────────────────────────────
    |> apply_latex_commands()
  end

  # Each pair is {latex_command, typst_equivalent}.
  # The regex engine appends (?![a-zA-Z]) so shorter commands never partially
  # match longer ones (e.g. \in does not fire inside \infty or \int).
  @latex_commands [
    # Integrals (longer forms first)
    {"\\iiint", "integral.triple"},
    {"\\iint", "integral.double"},
    {"\\oint", "integral.cont"},
    {"\\int", "integral"},
    # Spacing
    {"\\,", "thin"},
    {"\\:", "med"},
    {"\\;", "thick"},
    {"\\!", ""},
    # Greek – variant forms before base forms
    {"\\varepsilon", "epsilon"},
    {"\\vartheta", "theta.alt"},
    {"\\varpi", "pi.alt"},
    {"\\varrho", "rho.alt"},
    {"\\varsigma", "sigma.alt"},
    {"\\varphi", "phi"},
    {"\\varnothing", "nothing"},
    {"\\alpha", "alpha"},
    {"\\beta", "beta"},
    {"\\gamma", "gamma"},
    {"\\delta", "delta"},
    {"\\epsilon", "epsilon"},
    {"\\zeta", "zeta"},
    {"\\eta", "eta"},
    {"\\theta", "theta"},
    {"\\iota", "iota"},
    {"\\kappa", "kappa"},
    {"\\lambda", "lambda"},
    {"\\mu", "mu"},
    {"\\nu", "nu"},
    {"\\xi", "xi"},
    {"\\pi", "pi"},
    {"\\rho", "rho"},
    {"\\sigma", "sigma"},
    {"\\tau", "tau"},
    {"\\upsilon", "upsilon"},
    {"\\phi", "phi.alt"},
    {"\\chi", "chi"},
    {"\\psi", "psi"},
    {"\\omega", "omega"},
    {"\\Gamma", "Gamma"},
    {"\\Delta", "Delta"},
    {"\\Theta", "Theta"},
    {"\\Lambda", "Lambda"},
    {"\\Xi", "Xi"},
    {"\\Pi", "Pi"},
    {"\\Sigma", "Sigma"},
    {"\\Upsilon", "Upsilon"},
    {"\\Phi", "Phi"},
    {"\\Psi", "Psi"},
    {"\\Omega", "Omega"},
    # Symbols
    {"\\infty", "infinity"},
    {"\\partial", "partial"},
    {"\\nabla", "nabla"},
    {"\\hbar", "planck.reduce"},
    {"\\ell", "ell"},
    {"\\emptyset", "nothing"},
    {"\\pm", "plus.minus"},
    {"\\mp", "minus.plus"},
    {"\\times", "times"},
    {"\\div", "div"},
    {"\\cdot", "dot.op"},
    {"\\leq", "lt.eq"},
    {"\\le", "lt.eq"},
    {"\\geq", "gt.eq"},
    {"\\ge", "gt.eq"},
    {"\\neq", "eq.not"},
    {"\\ne", "eq.not"},
    {"\\approx", "approx"},
    {"\\equiv", "equiv"},
    {"\\propto", "prop"},
    {"\\sim", "tilde.op"},
    {"\\subseteq", "subset.eq"},
    {"\\subset", "subset"},
    {"\\supseteq", "supset.eq"},
    {"\\supset", "supset"},
    {"\\setminus", "without"},
    {"\\ll", "lt.double"},
    {"\\gg", "gt.double"},
    {"\\mid", "|"},
    {"\\bigcup", "union.big"},
    {"\\bigcap", "sect.big"},
    {"\\cup", "union"},
    {"\\cap", "sect"},
    {"\\notin", "in.not"},
    {"\\in", "in"},
    {"\\Leftrightarrow", "arrow.l.r.double"},
    {"\\leftrightarrow", "<->"},
    {"\\Rightarrow", "=>"},
    {"\\rightarrow", "->"},
    {"\\Leftarrow", "arrow.l.double"},
    {"\\leftarrow", "<-"},
    {"\\to", "->"},
    {"\\iff", "arrow.l.r.double"},
    {"\\implies", "=>"},
    {"\\forall", "forall"},
    {"\\exists", "exists"},
    {"\\neg", "not"},
    {"\\lnot", "not"},
    {"\\land", "and"},
    {"\\wedge", "and"},
    {"\\lor", "or"},
    {"\\vee", "or"},
    {"\\perp", "perp"},
    {"\\parallel", "parallel"},
    {"\\ldots", "..."},
    {"\\cdots", "..."},
    {"\\dots", "..."},
    {"\\vdots", "dots.v"},
    {"\\ddots", "dots.d"},
    {"\\Re", "Re"},
    {"\\Im", "Im"},
    {"\\sum", "sum"},
    {"\\prod", "product"},
    # Math functions – Typst renders these upright automatically
    {"\\arctan", "arctan"},
    {"\\arccos", "arccos"},
    {"\\arcsin", "arcsin"},
    {"\\tanh", "tanh"},
    {"\\cosh", "cosh"},
    {"\\sinh", "sinh"},
    {"\\tan", "tan"},
    {"\\cos", "cos"},
    {"\\sin", "sin"},
    {"\\log", "log"},
    {"\\ln", "ln"},
    {"\\exp", "exp"},
    {"\\lim", "lim"},
    {"\\max", "max"},
    {"\\min", "min"},
    {"\\sup", "sup"},
    {"\\inf", "inf"},
    {"\\det", "det"},
    {"\\dim", "dim"},
    {"\\ker", "ker"},
    {"\\gcd", "gcd"},
    {"\\deg", "deg"}
  ]

  defp apply_latex_commands(math) do
    Enum.reduce(@latex_commands, math, fn {latex, typst}, acc ->
      pattern = Regex.compile!(Regex.escape(latex) <> "(?![a-zA-Z])")
      Regex.replace(pattern, acc, typst)
    end)
  end

  defp scientific_styles do
    [
      Folio.Styles.page_size(width: 595, height: 842),
      Folio.Styles.page_margin(top: 71, bottom: 71, left: 85, right: 85),
      Folio.Styles.font_size(11),
      Folio.Styles.par_justify(true),
      Folio.Styles.page_numbering("1"),
      Folio.Styles.hyphenate(true)
    ]
  end
end
