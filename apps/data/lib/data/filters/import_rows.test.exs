defmodule Data.Filters.ImportRowsTest do
  @moduledoc """
  `Data.Filters.ImportRows` through `Data.Imports.rows_page/4`: `result`
  and `tab` against a direct query, the keyset order, the 422.
  """

  use Data.DataCase, async: true

  alias Data.Imports
  alias Data.Imports.Row

  @now ~U[2026-11-15 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    team = team_fixture(org)

    {:ok, import} =
      Imports.create(%{
        organisation_id: org.id,
        team_id: team.id,
        file_name: "a.xlsx",
        kind: :applications
      })

    rows =
      for tab <- ["2024", "2025"],
          n <- 2..4,
          do: %{tab: tab, row_number: n, cells: %{"A" => "#{n}"}}

    :ok = Imports.put_rows(import, rows, @now)

    results = [:new, :error, :duplicate, :new, :skipped, :update]

    import.id
    |> Imports.rows()
    |> Enum.zip(results)
    |> Enum.each(fn {row, result} -> {:ok, _row} = Imports.update_row(row, %{result: result}) end)

    %{import: import}
  end

  defp page(c, where, after_key \\ nil, limit \\ 50) do
    {:ok, rows} = Imports.rows_page(c.import.id, where, after_key, limit)
    Enum.map(rows, &{&1.tab, &1.row_number})
  end

  defp direct(c, query),
    do:
      from(r in query,
        where: r.import_id == ^c.import.id,
        order_by: [asc: r.tab, asc: r.row_number]
      )
      |> Repo.all()
      |> Enum.map(&{&1.tab, &1.row_number})

  test "result: $EQUAL and $IN, as a direct query", c do
    assert page(c, %{"result" => %{"$EQUAL" => "new"}}) ==
             direct(c, from(r in Row, where: r.result == :new))

    assert page(c, %{"result" => "error"}) == [{"2024", 3}]

    assert page(c, %{"result" => %{"$IN" => ["duplicate", "update"]}}) ==
             direct(c, from(r in Row, where: r.result in [:duplicate, :update]))
  end

  test "tab, and the keyset by tab and row number", c do
    assert page(c, %{"tab" => %{"$EQUAL" => "2025"}}) == [{"2025", 2}, {"2025", 3}, {"2025", 4}]
    assert page(c, %{}, nil, 2) == [{"2024", 2}, {"2024", 3}, {"2024", 4}]
    assert page(c, nil, {"2024", 4}) == [{"2025", 2}, {"2025", 3}, {"2025", 4}]
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"result" => "maybe"}, "result"},
          {%{"cells" => "x"}, "cells"},
          {%{"tab" => %{"$IN" => ["2024"]}}, "tab"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Imports.rows_page(c.import.id, where, nil, 10)
    end
  end
end
