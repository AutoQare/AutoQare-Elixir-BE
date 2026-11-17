defmodule Core.Meetings.NoticesTest do
  @moduledoc """
  AQ-10B §5.5 through the meeting verbs: a customer with no portal login
  mailed the meeting with its `.ics` (QP10b-2) and nothing for the 1 h
  reminder; a clash with another of the customer's meetings told to the
  owner and staff attendees; scheduled and changed passing quiet hours
  within 24 hours; the `ORGANIZER` line (QP10b-21).
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Meetings
  alias Core.Meetings.Notices
  alias Data.Notifications.{CustomerMails, Deliveries, Notification}

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)

    job =
      job_fixture(fiza,
        team: c.backend,
        title: "Backend Developer",
        company: company_fixture(c.org, name: "Corvid Security")
      )

    sara_cv = profile_fixture(c.sara, title: "Sara's CV", owners: [c.fiza])
    Map.merge(c, %{fiza_s: fiza, job: job, sara_cv: sara_cv})
  end

  defp schedule(c, lead, starts, attendees \\ []) do
    Meetings.schedule(
      c.fiza_s,
      lead.id,
      %{
        title: "Technical interview",
        meeting_kind: "technical",
        platform: "google_meet",
        join_url: "https://meet.google.com/abc-defg-hij",
        starts_at: DateTime.to_iso8601(starts),
        ends_at: DateTime.to_iso8601(DateTime.add(starts, 3600, :second)),
        time_zone: "Asia/Karachi",
        attendees: attendees
      },
      @now
    )
  end

  defp rows(user_id, kind) do
    from(n in Notification, where: n.user_id == ^user_id and n.notification_kind_key == ^kind)
    |> Repo.all()
  end

  test "a customer with no portal login is mailed the meeting with its .ics, once", c do
    lead = lead_fixture(c.fiza_s, job: c.job, profile: c.sara_cv, as: :apply)
    {:ok, m} = schedule(c, lead, DateTime.add(@now, 3 * 86_400, :second))

    assert [mail] = CustomerMails.for_customer(c.sara.id)
    assert mail.kind_key == "meetings.scheduled" and mail.state == :pending
    assert mail.subject =~ "Technical interview with Corvid Security"
    assert mail.text =~ "Join: https://meet.google.com/abc-defg-hij"
    assert mail.ics =~ "METHOD:REQUEST"
    assert mail.ics =~ "ORGANIZER;CN=\"Fiza\":mailto:"

    # The 24 h reminder mails too; the 1 h one doesn't.
    meeting = Data.Meetings.get_for_system(m.id)
    _ = Notices.reminder(Data.Scope.system(c.org), meeting, 1440)
    _ = Notices.reminder(Data.Scope.system(c.org), meeting, 60)
    _ = Notices.reminder(Data.Scope.system(c.org), meeting, 1440)

    assert ["meetings.day_before", "meetings.scheduled"] =
             c.sara.id |> CustomerMails.for_customer() |> Enum.map(& &1.kind_key) |> Enum.sort()
  end

  test "a meeting within 24 hours passes quiet hours", c do
    {:ok, _} =
      Data.Accounts.put_settings(c.qasim.id, %{
        quiet_hours_start: ~T[00:00:00],
        quiet_hours_end: ~T[23:59:00]
      })

    push_subscription_fixture(c.qasim)
    lead = lead_fixture(c.fiza_s, job: c.job, profile: c.golang, as: :apply, owner: c.qasim)

    hira = %{c | fiza_s: scope_for(c.hira)}
    {:ok, _soon} = schedule(hira, lead, DateTime.add(DateTime.utc_now(), 3 * 3600, :second))
    [soon] = rows(c.qasim.id, "meetings.scheduled")
    assert [%{channel: :push, deferred: false}, _email] = Deliveries.for_notification(soon.id)
  end

  test "a meeting saved over another of the customer's tells the owner and staff attendees", c do
    starts = DateTime.add(@now, 2 * 86_400, :second)
    lead = lead_fixture(c.fiza_s, job: c.job, profile: c.golang, as: :apply)
    {:ok, _first} = schedule(c, lead, starts)

    other_job = job_fixture(c.fiza_s, team: c.backend, title: "Go Engineer")
    other = lead_fixture(c.fiza_s, job: other_job, profile: c.golang, as: :apply, owner: c.qasim)
    hira = %{c | fiza_s: scope_for(c.hira)}

    {:ok, _second} =
      schedule(hira, other, DateTime.add(starts, 1800, :second), [%{user_id: c.muaz.id}])

    assert [%{title: "Technical interview clashes: " <> _}] = rows(c.qasim.id, "meetings.clash")
    assert [_] = rows(c.muaz.id, "meetings.clash")
    assert rows(c.hira.id, "meetings.clash") == []
  end
end
