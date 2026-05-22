defmodule LivebookToPdfTest do
  use ExUnit.Case

  alias LivebookToPdf.Parser
  alias LivebookToPdf.FolioConverter

  # ── Parser tests ─────────────────────────────────────────────────────────────

  describe "Parser.parse/1" do
    test "returns markdown block for plain text" do
      {:ok, blocks} = Parser.parse("# Hello\n\nSome text.")
      assert length(blocks) == 1
      assert hd(blocks).type == :markdown
      assert hd(blocks).content =~ "Hello"
    end

    test "tags elixir code blocks as :code" do
      content = """
      Some text.

      ```elixir
      x = 1 + 1
      ```

      More text.
      """

      {:ok, blocks} = Parser.parse(content)
      types = Enum.map(blocks, & &1.type)
      assert :code in types
      assert :markdown in types
      refute :output in types
    end

    test "tags output blocks correctly" do
      content = """
      ```elixir
      1 + 1
      ```

      <!-- livebook:{"output":true} -->

      ```
      2
      ```
      """

      {:ok, blocks} = Parser.parse(content)
      types = Enum.map(blocks, & &1.type)
      assert :code in types
      assert :output in types
    end

    test "force_markdown annotation marks block as markdown" do
      content = """
      <!-- livebook:{"force_markdown":true} -->

      ```
      This is markdown content.
      ```
      """

      {:ok, blocks} = Parser.parse(content)
      assert Enum.all?(blocks, &(&1.type == :markdown))
    end

    test "handles empty input" do
      {:ok, blocks} = Parser.parse("")
      assert blocks == []
    end

    test "multiple code and output blocks are parsed in order" do
      content = """
      # Title

      ```elixir
      data = [1, 2, 3]
      ```

      <!-- livebook:{"output":true} -->

      ```html
      <table><tr><td>1</td></tr></table>
      ```

      ## Section

      More text.
      """

      {:ok, blocks} = Parser.parse(content)
      assert length(blocks) >= 3

      types = Enum.map(blocks, & &1.type)
      assert :markdown in types
      assert :code in types
      assert :output in types
    end
  end

  # ── FolioConverter tests ──────────────────────────────────────────────────────

  describe "FolioConverter.to_markdown/2" do
    test "strips code blocks from output" do
      blocks = [
        %{type: :markdown, language: nil, content: "Text before."},
        %{type: :code, language: "elixir", content: "x = secret()"},
        %{type: :markdown, language: nil, content: "Text after."}
      ]

      md = FolioConverter.to_markdown(blocks)
      refute md =~ "secret()"
      assert md =~ "Text before"
      assert md =~ "Text after"
    end

    test "includes plain text output as blockquote" do
      blocks = [%{type: :output, language: "", content: "42"}]
      md = FolioConverter.to_markdown(blocks)
      assert md =~ "> 42"
    end

    test "converts HTML table output to Markdown table" do
      html =
        "<table><thead><tr><th>Name</th><th>Score</th></tr></thead>" <>
          "<tbody><tr><td>Alice</td><td>95</td></tr></tbody></table>"

      blocks = [%{type: :output, language: "html", content: html}]
      md = FolioConverter.to_markdown(blocks)

      assert md =~ "| Name | Score |"
      assert md =~ "| Alice | 95 |"
      assert md =~ "| --- |"
    end

    test "vega-lite output emits placeholder note" do
      blocks = [%{type: :output, language: "vega-lite", content: "{\"mark\":\"bar\"}"}]
      md = FolioConverter.to_markdown(blocks)
      assert md =~ "VegaLite chart"
    end

    test "opts[:title] replaces the first H1" do
      blocks = [%{type: :markdown, language: nil, content: "# Original\n\nBody."}]
      md = FolioConverter.to_markdown(blocks, title: "Override")
      assert md =~ "# Override"
      refute md =~ "# Original"
    end

    test "opts[:title] prepends an H1 when none exists" do
      blocks = [%{type: :markdown, language: nil, content: "Just a paragraph."}]
      md = FolioConverter.to_markdown(blocks, title: "My Title")
      assert md =~ "# My Title"
    end

    test "opts[:author] is inserted after the first heading" do
      blocks = [%{type: :markdown, language: nil, content: "# Paper\n\nBody."}]
      md = FolioConverter.to_markdown(blocks, author: "Jane Doe")
      lines = String.split(md, "\n")
      heading_idx = Enum.find_index(lines, &String.starts_with?(&1, "#"))
      meta_idx = Enum.find_index(lines, &String.contains?(&1, "Jane Doe"))
      assert meta_idx == heading_idx + 1
    end

    test "opts[:author] and opts[:date] are combined" do
      blocks = [%{type: :markdown, language: nil, content: "# Paper\n\nBody."}]
      md = FolioConverter.to_markdown(blocks, author: "Jane", date: "2026")
      assert md =~ "Jane · 2026"
    end

    test "markdown blocks pass through unchanged" do
      content = "# Title\n\nParagraph with **bold** and $E = mc^2$ math."
      blocks = [%{type: :markdown, language: nil, content: content}]
      md = FolioConverter.to_markdown(blocks)
      assert md =~ "**bold**"
      assert md =~ "$E = mc^2$"
    end
  end

  describe "FolioConverter.build_document/2" do
    test "returns a Folio.Document struct" do
      blocks = [%{type: :markdown, language: nil, content: "# Hello\n\nWorld."}]
      assert {:ok, %Folio.Document{}} = FolioConverter.build_document(blocks)
    end

    test "document contains styles" do
      blocks = [%{type: :markdown, language: nil, content: "Text."}]
      {:ok, doc} = FolioConverter.build_document(blocks)
      assert doc.styles != []
    end

    test "vegalite block renders SVG and attaches it to document" do
      spec = """
      {
        "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
        "data": {"values": [{"x": "A", "y": 1}, {"x": "B", "y": 2}]},
        "mark": "bar",
        "encoding": {
          "x": {"field": "x", "type": "nominal"},
          "y": {"field": "y", "type": "quantitative"}
        }
      }
      """
      blocks = [%{type: :output, language: "vega-lite", content: spec}]
      {:ok, doc} = FolioConverter.build_document(blocks)
      assert map_size(doc.files) == 1
      [{filename, bytes}] = Map.to_list(doc.files)
      assert String.ends_with?(filename, ".svg")
      assert byte_size(bytes) > 0
    end

    test "handles neq, nrightarrow, and unicode single-token subscripts" do
      math = "$lim_{λ→∞}E_{i,j}[d_λ(\\Xi_i,\\Xi_j)]≠0 \nrightarrow 1$"
      blocks = [%{type: :markdown, language: nil, content: "# Math\n\n" <> math}]

      assert {:ok, %Folio.Document{}} = FolioConverter.build_document(blocks)
    end
  end
end
