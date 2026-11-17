defmodule Core.Notifications.SnoozeTest do
  use ExUnit.Case, async: true

  alias Core.Notifications.Snooze

  doctest Snooze

  test "until Monday from a Monday is the next one; a bad choice is a field error" do
    # Monday 16 Nov 10:00 in Karachi.
    assert Snooze.until("monday", ~U[2026-11-16 05:00:00Z], "Asia/Karachi") ==
             {:ok, ~U[2026-11-23 03:00:00Z]}

    assert {:error, {:invalid, %{"for" => _}}} =
             Snooze.until("week", ~U[2026-11-16 05:00:00Z], "Etc/UTC")
  end
end
