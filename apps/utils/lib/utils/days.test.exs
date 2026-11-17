defmodule Utils.DaysTest do
  @moduledoc "Calendar days in a zone: today, a day's first instant, a window."

  use ExUnit.Case, async: true

  doctest Utils.Days

  alias Utils.Days

  test "today is the local day: late evening in Karachi is tomorrow there" do
    assert Days.today(~U[2026-11-14 20:00:00Z], "Asia/Karachi") == ~D[2026-11-15]
    assert Days.today(~U[2026-11-14 20:00:00Z], "Etc/UTC") == ~D[2026-11-14]
    assert Days.today(~U[2026-11-14 20:00:00Z], "Not/AZone") == ~D[2026-11-14]
  end

  test "a window runs from the first day's midnight to the midnight after the last" do
    assert Days.window(~D[2026-11-14], ~D[2026-11-14], "Asia/Karachi") ==
             {~U[2026-11-13 19:00:00.000000Z], ~U[2026-11-14 19:00:00.000000Z]}
  end
end
