defmodule Core.Imports.ReadTest do
  @moduledoc """
  `Core.Imports.Read`: a CSV (comma or semicolon, a byte-order mark,
  Latin-1, blank rows, row numbers), an .xlsx built here with `:zip`
  (every tab, a date cell, numbers, inline strings), and the caps.
  """

  use ExUnit.Case, async: true

  alias Core.Imports.Read

  @limits %{max_rows: 60, max_bytes: 200_000}

  test "a CSV: one tab named after the file, the header, row numbers, blank rows skipped" do
    csv =
      "﻿Sr #,Date,Job link\r\n1,09/10/2024,https://a.example/jobs/1\r\n,,\r\n2, 10/9/2026 ,\r\n"

    assert {:ok, [tab]} = Read.tabs(csv, "Fiza_Applications_2024.csv", @limits)
    assert tab.name == "Fiza_Applications_2024"
    assert tab.headers == ["Sr #", "Date", "Job link"]
    assert tab.samples["Job link"] == "https://a.example/jobs/1"

    assert [%{row_number: 2, cells: first}, %{row_number: 4, cells: second}] = tab.rows

    assert first == %{
             "Sr #" => "1",
             "Date" => "09/10/2024",
             "Job link" => "https://a.example/jobs/1"
           }

    assert second == %{"Sr #" => "2", "Date" => "10/9/2026"}
  end

  test "a semicolon CSV, and one in Latin-1" do
    assert {:ok, [tab]} =
             Read.tabs("Name;Company\nMei Chen;Initech, Inc\n", "people.csv", @limits)

    assert [%{cells: %{"Name" => "Mei Chen", "Company" => "Initech, Inc"}}] = tab.rows

    latin1 = "Name,City\nJos" <> <<0xE9>> <> ",Montr" <> <<0xE9>> <> "al\n"

    assert {:ok, [%{rows: [%{cells: %{"Name" => "José", "City" => "Montréal"}}]}]} =
             Read.tabs(latin1, "x.csv", @limits)
  end

  test "repeated and blank headers are named apart" do
    assert {:ok, [tab]} = Read.tabs("Email,,Email\na@x.example,b,c@x.example\n", "x.csv", @limits)
    assert tab.headers == ["Email", "Column 2", "Email (2)"]
  end

  test "an .xlsx: every tab, a date cell as ISO, numbers as written" do
    xlsx =
      workbook([
        {"2024",
         [
           [{:s, "Date"}, {:s, "Job Title"}, {:s, "Sr #"}],
           [{:date, 45_574}, {:s, "Backend Developer"}, {:n, "1"}],
           [],
           [{:s, "10/9/2026"}, {:s, "Go Engineer"}, {:n, "2.5"}]
         ]},
        {"2025", [[{:s, "Date"}], [{:s, "01/01/2025"}]]}
      ])

    assert {:ok, [first, second]} = Read.tabs(xlsx, "sheets.xlsx", @limits)
    assert first.name == "2024" and second.name == "2025"
    assert first.headers == ["Date", "Job Title", "Sr #"]

    assert [
             %{
               row_number: 2,
               cells: %{"Date" => "2024-10-09", "Job Title" => "Backend Developer", "Sr #" => "1"}
             },
             %{row_number: 4, cells: %{"Date" => "10/9/2026", "Sr #" => "2.5"}}
           ] = first.rows

    assert :ok = Read.check(xlsx, "sheets.xlsx", @limits)
  end

  test "the caps and what can't be read" do
    rows = Enum.map_join(1..61, "", &"#{&1},x\n")
    assert {:error, {:import_too_large, @limits}} = Read.check("A,B\n" <> rows, "x.csv", @limits)
    assert {:error, {:import_too_large, @limits}} = Read.tabs("A,B\n" <> rows, "x.csv", @limits)
    assert :ok = Read.check("A,B\n1,2\n", "x.csv", @limits)

    assert {:error, {:import_too_large, _limits}} =
             Read.check(:binary.copy("a", 200_001), "x.csv", @limits)

    assert {:error, :import_unreadable} = Read.check(<<0, 1, 2>>, "x.csv", @limits)
    assert {:error, {:import_unreadable, _words}} = Read.tabs("\n\n", "x.csv", @limits)
    assert {:error, {:import_unreadable, _words}} = Read.tabs("A,\"B\n1,2", "x.csv", @limits)
  end

  # ── A workbook, by hand ─────────────────────────────────────────────────────

  @ns ~s(xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main")
  @rel "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  defp workbook(sheets) do
    indexed = Enum.with_index(sheets, 1)

    files =
      [
        {"[Content_Types].xml",
         ~s(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>)},
        {"xl/workbook.xml",
         ~s(<?xml version="1.0"?><workbook #{@ns} xmlns:r="#{@rel}"><sheets>) <>
           Enum.map_join(indexed, fn {{name, _rows}, i} ->
             ~s(<sheet name="#{name}" sheetId="#{i}" r:id="rId#{i}"/>)
           end) <> "</sheets></workbook>"},
        {"xl/_rels/workbook.xml.rels",
         ~s(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
           Enum.map_join(indexed, fn {_sheet, i} ->
             ~s(<Relationship Id="rId#{i}" Type="#{@rel}/worksheet" Target="worksheets/sheet#{i}.xml"/>)
           end) <>
           ~s(<Relationship Id="rIdS" Type="#{@rel}/styles" Target="styles.xml"/></Relationships>)},
        {"xl/styles.xml",
         ~s(<?xml version="1.0"?><styleSheet #{@ns}><cellXfs count="2"><xf numFmtId="0"/>) <>
           ~s(<xf numFmtId="14" applyNumberFormat="1"/></cellXfs></styleSheet>)}
      ] ++
        Enum.map(indexed, fn {{_name, rows}, i} ->
          {"xl/worksheets/sheet#{i}.xml", sheet(rows)}
        end)

    {:ok, {_name, bytes}} =
      :zip.create(
        ~c"book.xlsx",
        Enum.map(files, fn {n, xml} -> {String.to_charlist(n), xml} end),
        [:memory]
      )

    bytes
  end

  defp sheet(rows) do
    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join(fn {cells, r} ->
        ~s(<row r="#{r}">) <>
          (cells
           |> Enum.with_index()
           |> Enum.map_join(fn {cell, c} -> cell(cell, <<?A + c>> <> "#{r}") end)) <>
          "</row>"
      end)

    ~s(<?xml version="1.0"?><worksheet #{@ns}><sheetData>#{body}</sheetData></worksheet>)
  end

  defp cell({:s, text}, ref), do: ~s(<c r="#{ref}" t="inlineStr"><is><t>#{text}</t></is></c>)
  defp cell({:n, n}, ref), do: ~s(<c r="#{ref}"><v>#{n}</v></c>)
  defp cell({:date, n}, ref), do: ~s(<c r="#{ref}" s="1"><v>#{n}</v></c>)
end
