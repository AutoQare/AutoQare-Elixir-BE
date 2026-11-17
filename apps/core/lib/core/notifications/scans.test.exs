defmodule Core.Notifications.ScansTest do
  @moduledoc """
  The notification scans (AQ-10B §5, §11.4), **each run twice**: the
  second run tells nobody again. The week's summary and report, an
  invitation's reminders, an untouched lead, stale triage, a silent
  forwarding address, a lead purged soon, a watch ending, the system
  admin's checks, a meeting unconfirmed and one with no outcome.
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  import Ecto.Query, only: [from: 2]

  alias Core.Dashboards
  alias Core.Dashboards.Windows
  alias Core.Notifications.Scans
  alias Data.Inbound.InboundMessage
  alias Data.Notifications.{CustomerMails, Notification}
  alias Data.Notifications.Deliveries

  # Monday 16 Nov 2026, 09:30 in Karachi.
  @monday ~U[2026-11-16 04:30:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.put(c, :fs, scope_for(c.fiza))
  end

  defp rows(user_id, kind) do
    from(n in Notification, where: n.user_id == ^user_id and n.notification_kind_key == ^kind)
    |> Repo.all()
  end

  defp twice(fun) do
    first = fun.()
    second = fun.()
    assert second.told == 0, "the second run told again: #{inspect(second)}"
    first
  end

  # AQ-11 QP11-12: the week is the dashboards' — the calendar week before
  # the Monday, counted from the ledger as the tiles count it — so the
  # applications are made through the verb, last Sunday and Saturday.
  test "the week: staff, a team lead, the customer's report, and by mail without a login",
       c do
    job = job_fixture(c.fs, team: c.backend, title: "Backend Developer")
    apply_at(c.fs, job, c.golang, DateTime.add(@monday, -86_400, :second))

    sara_cv = profile_fixture(c.sara, title: "Sara's CV", owners: [c.fiza])
    other = job_fixture(c.fs, team: c.backend, title: "Go Engineer")
    apply_at(c.fs, other, sara_cv, DateTime.add(@monday, -2 * 86_400, :second))

    # This Monday's work is next week's.
    apply_at(
      c.fs,
      job_fixture(c.fs, team: c.backend),
      c.golang,
      DateTime.add(@monday, -3600, :second)
    )

    did = twice(fn -> Scans.weekly(@monday) end)
    assert did.told >= 3

    assert [%{title: "Your week: 2 applications, 0 responses, 0 interviews"}] =
             rows(c.fiza.id, "account.weekly_summary")

    # The same numbers as the tiles for that week.
    last_week = Windows.window(~D[2026-11-09], ~D[2026-11-15], "Asia/Karachi")
    assert %{applications: 2} = Dashboards.numbers(c.fs, {:person, c.fiza.id}, last_week)

    assert [%{title: "Your team's week: 2 applications, 0 responses, 0 interviews"}] =
             rows(c.hira.id, "account.weekly_summary")

    assert [%{title: "Your week: 1 application, 0 replies, 0 interviews"}] =
             rows(c.tanweer.user_id, "leads.weekly_report")

    assert [%{kind_key: "leads.weekly_report", subject: "Your week: 1 application" <> _}] =
             CustomerMails.for_customer(c.sara.id)

    # Nothing to say, nothing sent: Muaz owns no lead.
    assert rows(c.muaz.id, "account.weekly_summary") == []

    # Not on a Tuesday.
    assert %{told: 0} = Scans.weekly(DateTime.add(@monday, 86_400, :second))
  end

  test "invitations: reminded three days on and the day before expiry, each once", c do
    inv = invitation_fixture(c.org, team: c.backend, invited_by_user_id: c.hira.id)

    three = DateTime.add(inv.inserted_at, 3 * 86_400 + 60, :second)
    assert %{reminded: 1} = Scans.invitations(three)
    assert %{reminded: 1} = Scans.invitations(three)

    last = DateTime.add(inv.expires_at, -3600, :second)
    assert %{reminded: 1} = Scans.invitations(last)

    jobs = all_enqueued(worker: "Notifire.Workers.InvitationWorker")

    assert ["last_day", "three_days"] =
             jobs |> Enum.map(& &1.args["options"]["when"]) |> Enum.sort()
  end

  test "a To do lead untouched a week tells its owner once per quiet stretch", c do
    now = ~U[2026-11-14 09:00:00.000000Z]

    lead =
      lead_fixture(c.fs,
        team: c.backend,
        profile: c.golang,
        last_activity_at: DateTime.add(now, -8 * 86_400, :second)
      )

    twice(fn -> Scans.untouched(now) end)
    assert [%{lead_id: id, title: title}] = rows(c.fiza.id, "leads.untouched")
    assert id == lead.id and title =~ "has sat in To do for a week"
  end

  test "a triage item unresolved 48 hours tells the team's leads once", c do
    now = ~U[2026-11-14 09:00:00.000000Z]
    conv = conversation_fixture(c.fs, team: c.backend)

    Repo.update_all(
      from(x in Data.Conversations.Conversation, where: x.id == ^conv.id),
      set: [inserted_at: DateTime.add(now, -3 * 86_400, :second), last_message_at: nil]
    )

    twice(fn -> Scans.triage_stale(now) end)

    assert [%{title: "Waiting in Triage for 2 days" <> _}] =
             rows(c.hira.id, "conversations.triage_stale")

    assert rows(c.fiza.id, "conversations.triage_stale") == []
  end

  test "an archived lead purged within 7 days tells the owner and the team's leads once", c do
    now = ~U[2026-11-14 09:00:00.000000Z]

    lead_fixture(c.fs,
      team: c.backend,
      profile: c.golang,
      archived: true,
      archived_at: DateTime.add(now, -85 * 86_400, :second)
    )

    twice(fn -> Scans.purge_soon(now) end)
    assert [%{title: title}] = rows(c.fiza.id, "leads.purge_soon")
    assert title =~ "will be cleared on"
    assert [_] = rows(c.hira.id, "leads.purge_soon")
  end

  test "a watch expiring within a day tells its watcher once", c do
    now = ~U[2026-11-14 09:00:00.000000Z]
    corvid = company_fixture(c.org, name: "Corvid Security")
    job_fixture(c.fs, team: c.backend, company: corvid)

    {:ok, {:created, _w}} =
      Core.Watches.create(
        c.fs,
        %{"company_id" => corvid.id, "trigger" => "posts_job", "expires_in" => "week"},
        DateTime.add(now, -6 * 86_400 - 3600, :second)
      )

    twice(fn -> Scans.watch_ending(now) end)

    assert [%{title: "Your watch on Corvid Security ends tomorrow"}] =
             rows(c.fiza.id, "behaviour.watch_ending")
  end

  test "meetings: unconfirmed within 24 h (owner and team leads), and no outcome 30 minutes after the end",
       c do
    now = ~U[2026-11-14 09:00:00.000000Z]
    lead = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
    proposed = meeting_fixture(c.fs, lead: lead, starts_at: DateTime.add(now, 6 * 3600, :second))

    Repo.update_all(from(m in Data.Meetings.Meeting, where: m.id == ^proposed.id),
      set: [status: :proposed, source: :email_invite]
    )

    meeting_fixture(c.fs, lead: lead, starts_at: DateTime.add(now, -2 * 3600, :second))

    twice(fn -> Scans.meetings(now) end)

    assert [%{title: "Technical interview is still unconfirmed · " <> _}] =
             rows(c.fiza.id, "meetings.unconfirmed")

    assert [_] = rows(c.hira.id, "meetings.unconfirmed")
    assert [%{title: "How did Technical interview go?"}] = rows(c.fiza.id, "meetings.log_outcome")
  end

  test "the system checks tell the system admin once an hour", c do
    now = ~U[2026-11-14 09:30:00.000000Z]
    n = notification_fixture(c.org, c.fiza)

    for _i <- 1..11 do
      Deliveries.insert_planned(
        %{n | id: notification_fixture(c.org, c.fiza).id},
        [%{channel: :email, deliver_after: now, deferred: false}],
        nil,
        now
      )
    end

    Repo.update_all(Data.Notifications.Delivery,
      set: [state: :failed, error: "mailbox unavailable", attempts: 3, updated_at: now]
    )

    twice(fn -> Scans.system(now) end)

    assert [%{title: "11 deliveries failed in the last hour"}] =
             rows(c.dawud.id, "system.delivery_failing")

    assert rows(c.hira.id, "system.delivery_failing") == []
  end

  test "a forwarding address silent 14 days tells the owners and the customer once per silence",
       c do
    now = ~U[2026-11-14 09:00:00.000000Z]
    channel = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@gmail.com")

    Repo.update_all(from(ch in Data.Customers.Channel, where: ch.id == ^channel.id),
      set: [inbound_token: "tok-#{System.unique_integer([:positive])}"]
    )

    {:ok, _} =
      %Data.Inbound.InboundMessage{}
      |> InboundMessage.changeset(%{
        organisation_id: c.org.id,
        channel_id: channel.id,
        provider: :dev,
        outcome: :landed,
        received_at: DateTime.add(now, -15 * 86_400, :second)
      })
      |> Repo.insert()

    twice(fn -> Scans.forwarding_silent(now) end)

    assert [%{title: "No mail from Tanweer's " <> _}] =
             rows(c.fiza.id, "conversations.forwarding_silent")

    assert [%{title: "No mail has reached your team since 30 Oct"}] =
             rows(c.tanweer.user_id, "conversations.forwarding_silent")
  end
end
