defmodule LivebookToPdf.Parser do
  @moduledoc """
  Parses Livebook (.livemd) files into structured content blocks.

  Livebook files are Markdown-based with special HTML comment annotations
  and fenced code blocks for elixir cells and their outputs.

  Block types returned:
    - `:markdown`  – regular markdown content (text, headings, tables, images)
    - `:code`      – elixir code cell (to be skipped when generating PDF)
    - `:output`    – result of an elixir cell (tables, text, etc.)
  """

  @type block :: %{
          type: :markdown | :code | :output,
          language: String.t() | nil,
          content: String.t()
        }

  @doc """
  Parses a Livebook file content string into a list of content blocks.
  """
  @spec parse(String.t()) :: {:ok, [block()]} | {:error, term()}
  def parse(content) when is_binary(content) do
    state = %{
      mode: :text,
      lines: [],
      blocks: [],
      next_is_output: false,
      next_is_markdown: false
    }

    blocks =
      content
      |> String.split("\n")
      |> parse_lines(state)

    {:ok, blocks}
  rescue
    e -> {:error, e}
  end

  # ── Line-by-line state machine ───────────────────────────────────────────────

  defp parse_lines([], state) do
    flush(state)
  end

  defp parse_lines([line | rest], %{mode: :text} = state) do
    cond do
      # Livebook annotation comment
      String.starts_with?(line, "<!-- livebook:") ->
        state = flush_text(state)
        meta = parse_annotation(line)
        state = %{
          state
          | next_is_output: Map.get(meta, "output", false),
            next_is_markdown: Map.get(meta, "force_markdown", false)
        }

        parse_lines(rest, state)

      # Start of a fenced code block (``` followed by optional language)
      String.starts_with?(line, "```") ->
        state = flush_text(state)
        language = line |> String.trim_leading("`") |> String.trim()
        is_output = state.next_is_output
        is_forced_markdown = state.next_is_markdown

        new_mode = {:code, language, is_output, is_forced_markdown}

        parse_lines(rest, %{state | mode: new_mode, lines: [], next_is_output: false, next_is_markdown: false})

      true ->
        parse_lines(rest, %{state | lines: [line | state.lines]})
    end
  end

  defp parse_lines([line | rest], %{mode: {:code, language, is_output, is_forced_markdown}} = state) do
    if line == "```" do
      content = state.lines |> Enum.reverse() |> Enum.join("\n")

      block_type =
        cond do
          is_forced_markdown -> :markdown
          is_output -> :output
          true -> :code
        end

      block = %{type: block_type, language: language, content: content}
      new_blocks = [block | state.blocks]
      parse_lines(rest, %{state | mode: :text, lines: [], blocks: new_blocks})
    else
      parse_lines(rest, %{state | lines: [line | state.lines]})
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp flush_text(%{lines: []} = state), do: state

  defp flush_text(%{lines: lines, blocks: blocks} = state) do
    content = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    if content == "" do
      %{state | lines: []}
    else
      block = %{type: :markdown, language: nil, content: content}
      %{state | lines: [], blocks: [block | blocks]}
    end
  end

  defp flush(state) do
    state
    |> flush_text()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
  end

  defp parse_annotation(line) do
    case Regex.run(~r/<!-- livebook:(\{.*?\}) -->/, line) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
