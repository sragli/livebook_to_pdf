# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-05-11

### Added

- **Livebook parser** — state-machine parser for `.livemd` files that handles
  `<!-- livebook:{...} -->` JSON annotations and correctly classifies blocks as
  `:markdown`, `:code`, or `:output`.
- **PDF generation** — converts parsed blocks to a `Folio.Document` and
  compiles to PDF via the Folio Typst NIF (`folio ~> 0.2.3`). Scientific
  article style: A4, 11 pt, justified text, numbered headings, page numbers.
- **VegaLite chart rendering** — VegaLite / Vega specs found in output blocks
  are rendered to SVG in-process using the `vega_lite_convert` Rustler NIF
  (wraps [vl-convert](https://github.com/vega/vl-convert)). No Node.js or
  other external runtime is required.
- **HTML table conversion** — `Kino.DataTable` HTML table outputs are parsed
  with Floki and converted to GitHub Flavored Markdown tables before PDF
  compilation.
- **Plain-text output** — plain expression results are formatted as blockquotes
  in the PDF.
- **`LivebookToPdf.convert/2`** — high-level function that reads a `.livemd`
  file and writes a PDF. Accepts `:output`, `:title`, `:author`, `:date`
  options.
- **`LivebookToPdf.to_markdown/2`** — returns the cleaned Markdown
  intermediate representation without compiling to PDF.
- **`mix livebook_to_pdf` task** — CLI interface with `--author`, `--title`,
  `--date`, and `--markdown-only` flags.
