# LivebookToPdf

Convert [Livebook](https://livebook.dev/) notebooks (`.livemd`) to
publication-ready PDFs in a scientific article format — entirely from within
your Mix project, with no external tools required.

The PDF is compiled by [Folio](https://hexdocs.pm/folio), an Elixir library
that wraps the [Typst](https://typst.app/) typesetting engine via a precompiled
Rustler NIF. VegaLite charts are rendered in-process by
[vega_lite_convert](https://hex.pm/packages/vega_lite_convert), another
precompiled Rustler NIF wrapping [vl-convert](https://github.com/vega/vl-convert).
Neither Node.js nor any other runtime needs to be installed.

## What is included

| Content | Converted |
|---|---|
| Headings, paragraphs, lists, blockquotes | ✅ |
| Markdown tables | ✅ |
| Inline and display math (`$…$` / `$$…$$`) | ✅ |
| Images referenced in the notebook | ✅ |
| HTML table outputs (e.g. `Kino.DataTable`) | ✅ converted to Markdown table |
| Plain-text expression results | ✅ formatted as blockquote |
| VegaLite / Vega chart specs | ✅ rendered to SVG via NIF |
| Elixir code cells | ❌ excluded by design |

## Installation

Add `livebook_to_pdf` to your dependencies:

```elixir
def deps do
  [
    {:livebook_to_pdf, "~> 0.1.0"}
  ]
end
```

## Usage

### As a library

```elixir
# Convert a notebook — saves PDF next to the .livemd file
{:ok, pdf_path} = LivebookToPdf.convert("report.livemd")

# Specify output path, author, and date
{:ok, pdf_path} = LivebookToPdf.convert("report.livemd",
  output: "~/Desktop/report.pdf",
  author: "Jane Doe",
  date: "2026-05-11"
)

# Only retrieve the cleaned Markdown (no PDF compilation)
{:ok, markdown} = LivebookToPdf.to_markdown("report.livemd")
```

### As a Mix task

```bash
# Basic conversion
mix livebook_to_pdf report.livemd

# Specify output path and author
mix livebook_to_pdf report.livemd ~/Desktop/report.pdf --author "Jane Doe"

# Only generate the intermediate Markdown file
mix livebook_to_pdf report.livemd --markdown-only
```

#### Mix task options

| Flag | Alias | Description |
|---|---|---|
| `--author NAME` | `-a` | Set the document author |
| `--title TITLE` | `-t` | Override the document title |
| `--date DATE` | | Set the date string |
| `--markdown-only` | | Write `.md` only, skip PDF compilation |

## Dependencies

All heavy lifting is done by precompiled NIFs — no Rust toolchain, no Node.js,
no LaTeX installation needed.

| Package | Purpose |
|---|---|
| [`folio ~> 0.2`](https://hex.pm/packages/folio) | PDF generation via Typst NIF |
| [`vega_lite ~> 0.1`](https://hex.pm/packages/vega_lite) | VegaLite spec builder |
| [`vega_lite_convert ~> 1.0`](https://hex.pm/packages/vega_lite_convert) | VegaLite → SVG/PNG via vl-convert NIF |
| [`jason ~> 1.4`](https://hex.pm/packages/jason) | JSON parsing for Livebook annotations |
| [`floki ~> 0.36`](https://hex.pm/packages/floki) | HTML table parsing |

