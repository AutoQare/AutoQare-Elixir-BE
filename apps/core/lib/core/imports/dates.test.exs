defmodule Core.Imports.DatesTest do
  @moduledoc "`Core.Imports.Dates`: each way a sheet writes a day, the order, the refusals."

  use ExUnit.Case, async: true

  alias Core.Imports.Dates

  doctest Dates

  @today ~D[2026-11-15]

  test "ISO, numbers in either order, month names, a spreadsheet's day number" do
    assert Dates.read("2024-10-09", :day_month, @today) == {:ok, ~D[2024-10-09]}
    assert Dates.read("2024-10-09T12:00:00Z", :day_month, @today) == {:ok, ~D[2024-10-09]}
    assert Dates.read("10-09-26", :day_month, @today) == {:ok, ~D[2026-09-10]}
    assert Dates.read("10.9.2026", "month_day", @today) == {:ok, ~D[2026-10-09]}
    assert Dates.read("9 Oct 2024", :month_day, @today) == {:ok, ~D[2024-10-09]}
    assert Dates.read("Oct 9, 2024", :day_month, @today) == {:ok, ~D[2024-10-09]}
    assert Dates.read("09-Oct-24", :day_month, @today) == {:ok, ~D[2024-10-09]}
    assert Dates.read("45574", :day_month, @today) == {:ok, ~D[2024-10-09]}
  end

  test "an impossible day, a day to come, nothing at all" do
    assert Dates.read("31/02/2024", :day_month, @today) == {:error, "31/02/2024 isn't a date."}
    assert Dates.read("13/13/2024", :day_month, @today) == {:error, "13/13/2024 isn't a date."}

    assert Dates.read("20/11/2026", :day_month, @today) ==
             {:error, "20/11/2026 is in the future."}

    assert Dates.read("soon", :day_month, @today) == {:error, "soon isn't a date."}
    assert Dates.read("", :day_month, @today) == {:error, "No date."}
    assert Dates.read(nil, :day_month, @today) == {:error, "No date."}
  end
end
