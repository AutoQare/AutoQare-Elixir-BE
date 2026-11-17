defmodule Core.Imports.StatusesTest do
  @moduledoc "`Core.Imports.Statuses`: §3.3's table and QP12-6 without a status."

  use ExUnit.Case, async: true

  alias Core.Imports.Statuses

  doctest Statuses

  @old ~D[2024-10-09]
  @recent ~D[2026-11-10]
  @today ~D[2026-11-15]

  test "§3.3, row by row" do
    in_progress = &%{state: :in_progress, stage_kind: &1, outcome: nil, at_days: 0}
    done = &%{state: :done, stage_kind: nil, outcome: &1, at_days: 0}

    for s <- ["Applied", "Follow-up due", "Followed up"],
        do: assert(Statuses.place(s, @old, @today, 14) == in_progress.(nil))

    assert Statuses.place("No response", @recent, @today, 14) == in_progress.(nil)
    assert Statuses.place("No response", @old, @today, 14).outcome == :no_response
    assert Statuses.place("Responded", @old, @today, 14) == in_progress.(:screening)
    assert Statuses.place("Info requested", @old, @today, 14) == in_progress.(:screening)
    assert Statuses.place("Interview scheduled", @old, @today, 14) == in_progress.(:interview)
    assert Statuses.place("Assessment", @old, @today, 14) == in_progress.(:assessment)
    assert Statuses.place("Offer", @old, @today, 14) == in_progress.(:offer)
    assert Statuses.place("Placed", @old, @today, 14) == done.(:hired)
    assert Statuses.place("Rejected", @old, @today, 14) == done.(:rejected)
    assert Statuses.place("Position closed", @old, @today, 14) == done.(:position_closed)
  end

  test "a status off the table is read as none, and known? says so" do
    refute Statuses.known?("Ghosted")
    assert Statuses.known?("")
    assert Statuses.known?(nil)
    assert Statuses.place("Ghosted", @recent, @today, 14).state == :in_progress
  end
end
