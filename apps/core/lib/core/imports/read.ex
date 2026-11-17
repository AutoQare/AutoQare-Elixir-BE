defmodule Core.Imports.Read do
  @moduledoc """
  An import's file read into tabs (AQ-12 §11.4), pure: bytes in, tabs out.

  - **`.csv`** through NimbleCSV: the byte-order mark stripped, a file that
    isn't UTF-8 read as Latin-1 (what Excel's "CSV" writes), comma or
    semicolon — whichever the header line holds more of. One tab, named
    after the file.
  - **`.xlsx`** through `XlsxReader`: every tab. A date cell becomes ISO
    `YYYY-MM-DD`, a number its digits (`45` not `45.0`), a boolean `TRUE` /
    `FALSE`.

  In each tab the first non-empty row is the header (a blank header is
  "Column N", a repeated one gains " (2)"); blank rows are skipped; every
  cell is trimmed text, and a row keeps its **sheet row number** (the
  header's own is counted). `check/3` is what `POST /imports` asks before
  answering: the size and the row count against the caps
  (`{:import_too_large, %{max_rows, max_bytes}}`), and that the bytes are
  a CSV or an XLSX at all (`:import_unreadable`).
  """

  alias Core.Storage.Content
  alias NimbleCSV.RFC4180, as: Comma

  NimbleCSV.define(__MODULE__.Semicolon, separator: ";", escape: "\"")

  alias __MODULE__.Semicolon

  @type tab :: %{
          name: String.t(),
          headers: [String.t()],
          samples: %{String.t() => String.t()},
          rows: [%{row_number: pos_integer(), cells: %{String.t() => String.t()}}]
        }

  @doc """
  Whether a file may be imported at all, without reading it whole: `:ok`,
  `{:error, {:import_too_large, limits}}` or `{:error, :import_unreadable}`.
  `limits` is `%{max_rows, max_bytes}`.
  """
  @spec check(binary(), String.t(), map()) :: :ok | {:error, term()}
  def check(bytes, _name, %{max_rows: rows, max_bytes: max} = limits) when is_binary(bytes) do
    cond do
      byte_size(bytes) > max -> {:error, {:import_too_large, limits}}
      xlsx?(bytes) -> within(xlsx_rows(bytes), rows, limits)
      text(bytes) -> within(csv_lines(text(bytes)), rows, limits)
      true -> {:error, :import_unreadable}
    end
  end

  defp within({:error, _reason} = error, _max, _limits), do: error
  defp within(n, max, limits) when n > max + 1, do: {:error, {:import_too_large, limits}}
  defp within(_n, _max, _limits), do: :ok

  @doc """
  The file's tabs, each with its headers, a sample of each header (its
  first non-blank value) and its rows: `{:ok, [tab]}`, `{:error,
  {:import_too_large, limits}}` over `max_rows` data rows in all, or
  `{:error, {:import_unreadable, words}}`.
  """
  @spec tabs(binary(), String.t(), map()) :: {:ok, [tab()]} | {:error, term()}
  def tabs(bytes, name, %{max_rows: max} = limits) when is_binary(bytes) do
    with {:ok, raw} <- raw_tabs(bytes, name) do
      tabs = raw |> Enum.map(fn {tab, rows} -> tab(tab, rows) end) |> Enum.reject(&is_nil/1)
      total = tabs |> Enum.map(&length(&1.rows)) |> Enum.sum()

      cond do
        tabs == [] -> {:error, {:import_unreadable, "That file has no header row to read."}}
        total > max -> {:error, {:import_too_large, limits}}
        true -> {:ok, tabs}
      end
    end
  end

  defp raw_tabs(bytes, name) do
    cond do
      xlsx?(bytes) ->
        xlsx(bytes)

      text(bytes) ->
        csv(text(bytes), name)

      true ->
        {:error,
         {:import_unreadable, "We couldn't read that file. Upload a .csv or an .xlsx file."}}
    end
  end

  # ── CSV ─────────────────────────────────────────────────────────────────────

  defp text(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: text(rest)

  defp text(bytes) do
    cond do
      String.contains?(bytes, <<0>>) -> nil
      String.valid?(bytes) -> bytes
      true -> latin1(bytes)
    end
  end

  defp latin1(bytes) do
    case :unicode.characters_to_binary(bytes, :latin1) do
      text when is_binary(text) -> text
      _error -> nil
    end
  end

  defp csv(text, name) do
    parser = if semicolons?(text), do: Semicolon, else: Comma

    rows =
      text
      |> parser.parse_string(skip_headers: false)
      |> Enum.with_index(1)
      |> Enum.map(fn {cells, n} -> {n, cells} end)

    {:ok, [{tab_name(name), rows}]}
  rescue
    _error in [NimbleCSV.ParseError] ->
      {:error, {:import_unreadable, "That CSV file has a quote that never closes."}}
  end

  defp semicolons?(text) do
    line = text |> String.split(["\r\n", "\n"], parts: 2) |> hd()
    count(line, ";") > count(line, ",")
  end

  defp count(text, char), do: length(String.split(text, char)) - 1

  defp csv_lines(text) do
    text |> String.split(["\r\n", "\n"]) |> Enum.count(&(String.trim(&1) != ""))
  end

  defp tab_name(name) do
    case name |> to_string() |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> "Sheet"
      tab -> String.slice(tab, 0, 100)
    end
  end

  # ── XLSX ────────────────────────────────────────────────────────────────────

  defp xlsx?(bytes), do: Content.detect(bytes) == Content.xlsx()

  defp xlsx(bytes) do
    with {:ok, package} <- XlsxReader.open(bytes, source: :binary),
         {:ok, sheets} <- XlsxReader.sheets(package, number_type: Decimal, empty_rows: true) do
      {:ok,
       Enum.map(sheets, fn {name, rows} ->
         {name, rows |> Enum.with_index(1) |> Enum.map(fn {cells, n} -> {n, cells} end)}
       end)}
    else
      _unreadable ->
        {:error,
         {:import_unreadable,
          "We couldn't read that .xlsx file. Save it again from your spreadsheet and retry."}}
    end
  rescue
    _error -> {:error, {:import_unreadable, "We couldn't read that .xlsx file."}}
  end

  # Rows in every worksheet, counted from the XML without parsing it — once
  # the workbook opens at all.
  defp xlsx_rows(bytes) do
    with {:ok, _package} <- XlsxReader.open(bytes, source: :binary),
         {:ok, files} <- :zip.unzip(bytes, [:memory]) do
      files
      |> Enum.filter(fn {path, _xml} ->
        String.starts_with?(to_string(path), "xl/worksheets/")
      end)
      |> Enum.map(fn {_path, xml} -> count(xml, "<row ") end)
      |> Enum.sum()
    else
      _error -> {:error, :import_unreadable}
    end
  rescue
    _error -> {:error, :import_unreadable}
  end

  # ── A tab ───────────────────────────────────────────────────────────────────

  defp tab(name, rows) do
    case Enum.drop_while(rows, fn {_n, cells} -> blank_row?(cells) end) do
      [] ->
        nil

      [{_n, header} | data] ->
        headers = headers(header)

        read =
          for {n, cells} <- data, not blank_row?(cells) do
            values = cells |> Enum.map(&text_of/1) |> Enum.take(length(headers))

            %{
              row_number: n,
              cells:
                headers
                |> Enum.zip(values)
                |> Enum.reject(fn {_header, value} -> value == "" end)
                |> Map.new()
            }
          end

        %{name: to_string(name), headers: headers, samples: samples(headers, read), rows: read}
    end
  end

  defp blank_row?(cells), do: Enum.all?(cells, &(text_of(&1) == ""))

  defp headers(cells) do
    cells
    |> Enum.map(&text_of/1)
    |> Enum.with_index(1)
    |> Enum.map(fn
      {"", i} -> "Column #{i}"
      {header, _i} -> header
    end)
    |> unique([], %{})
    |> trim_trailing_blank(cells)
  end

  defp unique([], acc, _seen), do: Enum.reverse(acc)

  defp unique([header | rest], acc, seen) do
    case Map.get(seen, header, 0) do
      0 -> unique(rest, [header | acc], Map.put(seen, header, 1))
      n -> unique(rest, ["#{header} (#{n + 1})" | acc], Map.put(seen, header, n + 1))
    end
  end

  # Trailing columns with no header at all are not columns.
  defp trim_trailing_blank(headers, cells) do
    kept = cells |> Enum.map(&text_of/1) |> Enum.reverse() |> Enum.drop_while(&(&1 == ""))
    Enum.take(headers, length(kept))
  end

  defp samples(headers, rows) do
    Map.new(headers, fn header ->
      {header, Enum.find_value(rows, "", &Map.get(&1.cells, header))}
    end)
  end

  @doc false
  # A cell as text: trimmed; a date ISO; a number without a trailing `.0`.
  def text_of(nil), do: ""
  def text_of(value) when is_binary(value), do: String.trim(value)
  def text_of(%Date{} = date), do: Date.to_iso8601(date)
  def text_of(%NaiveDateTime{} = at), do: at |> NaiveDateTime.to_date() |> Date.to_iso8601()
  def text_of(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  def text_of(%Decimal{} = n), do: n |> Decimal.normalize() |> Decimal.to_string(:normal)
  def text_of(true), do: "TRUE"
  def text_of(false), do: "FALSE"
  def text_of(n) when is_integer(n), do: Integer.to_string(n)

  def text_of(n) when is_float(n),
    do: if(n == Float.round(n), do: n |> trunc() |> Integer.to_string(), else: Float.to_string(n))

  def text_of(other), do: other |> to_string() |> String.trim()
end
