defmodule Core.Workers.NotificationScanTest do
  @moduledoc """
  The three notification scan workers of AQ-10B §11.4 (`WeeklyScan`,
  `NotificationScan`, `MeetingNoticeScan`), each **run twice** with the
  clock frozen: the second run tells nobody. They hold no rule; the rules
  are `Core.Notifications.Scans` and `Weekly`, tested on their own.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Clock
  alias Core.Workers.{MeetingNoticeScan, NotificationScan, WeeklyScan}

  # Monday 16 Nov 2026, 09:30 in Karachi.
  @monday ~U[2026-11-16 04:30:00.000000Z]

  setup do
    on_exit(&Clock.unfreeze/0)
    board_cast_fixture()
  end

  defp count, do: Repo.aggregate(Data.Notifications.Notification, :count)

  test "each runs twice and the second run adds nothing", c do
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend)

    # Through the verb: the week's numbers are read from the ledger (AQ-11 QP11-12).
    lead = apply_at(fiza, job, c.golang, DateTime.add(@monday, -86_400, :second))

    meeting_fixture(fiza, lead: lead, starts_at: DateTime.add(@monday, -2 * 3600, :second))

    lead_fixture(fiza,
      team: c.backend,
      profile: c.golang,
      last_activity_at: DateTime.add(@monday, -8 * 86_400, :second)
    )

    Clock.freeze(@monday)

    for worker <- [WeeklyScan, NotificationScan, MeetingNoticeScan] do
      assert :ok = worker.perform(%Oban.Job{args: %{}})
      after_first = count()
      assert :ok = worker.perform(%Oban.Job{args: %{}})
      assert count() == after_first, "#{inspect(worker)} told twice"
    end

    kinds =
      Repo.all(from(n in Data.Notifications.Notification, select: n.notification_kind_key))

    assert "account.weekly_summary" in kinds
    assert "leads.untouched" in kinds
    assert "meetings.log_outcome" in kinds
  end
end
