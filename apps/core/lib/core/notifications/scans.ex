defmodule Core.Notifications.Scans do
  @moduledoc """
  The notification scans (AQ-10B §5, §11.4): the events nobody's verb
  raises, found by time. **Each is idempotent** — every row it writes is
  ensured by a dedupe key that names the moment it is about — so a second
  run, or the dev sweeps after the cron, tells nobody twice. Rules take
  `now`; the workers (`Core.Workers.WeeklyScan`, `NotificationScan`,
  `MeetingNoticeScan`) only hand them the clock.

  | Scan | Tells | When |
  |---|---|---|
  | `weekly/1` | `account.weekly_summary` (staff "your week", team leads "your team's week") and `leads.weekly_report` (customers; by mail without a login) | Monday at the digest time (staff), Monday 09:00 in the customer's zone; nothing to say, nothing sent |
  | `invitations/1` | the invitee's reminders (3 days on, the day before expiry; mail) and `account.invitation_expired` | hourly |
  | `untouched/1` | `leads.untouched`: a To do lead untouched 7 days, its owner, once per quiet stretch | hourly |
  | `triage_stale/1` | `conversations.triage_stale`: a triage item unresolved 48 h, the team's leads | hourly |
  | `forwarding_silent/1` | `conversations.forwarding_silent`: a forwarding address silent 14 days after it had mail, the owners and the customer, once per silence | hourly |
  | `purge_soon/1` | `leads.purge_soon`: an archived lead purged within 7 days, its owner and the team's leads | hourly |
  | `watch_ending/1` | `behaviour.watch_ending`: a watch expiring within a day, its watcher | hourly |
  | `system/1` | the system admin: `system.selectors_failing` (25 misses of a site in a day), `system.delivery_failing` (over 10 failed deliveries in an hour), `system.inbound_failing` (over 5 unreadable or oversized forwarded mails in an hour), `system.jobs_discarded` (any discarded background job in an hour) | hourly |
  | `meetings/1` | `meetings.unconfirmed` (proposed, starting within 24 h: owner and team leads) and `meetings.log_outcome` (30 minutes after a meeting's end with no outcome: owner) | every 10 minutes |
  """

  alias Core.Leads.Words, as: LeadWords
  alias Core.Meetings.Words, as: MeetingWords
  alias Core.Notifications
  alias Core.Notifications.Weekly
  alias Core.Organisation.Invitations
  alias Data.Notifications.Scans, as: Store
  alias Data.Scope
  alias Data.Teams

  @hour 3600
  @day 86_400
  @selector_threshold 25
  @delivery_threshold 10
  @inbound_threshold 5

  @doc "Every scan at `now`, as the dev sweeps run them: `[{name, %{told}}]`."
  @spec run_all(DateTime.t()) :: [{String.t(), map()}]
  def run_all(%DateTime{} = now) do
    [
      {"weekly", weekly(now)},
      {"invitations", invitations(now)},
      {"untouched", untouched(now)},
      {"triage_stale", triage_stale(now)},
      {"forwarding_silent", forwarding_silent(now)},
      {"purge_soon", purge_soon(now)},
      {"watch_ending", watch_ending(now)},
      {"system_checks", system(now)},
      {"meeting_notices", meetings(now)}
    ]
  end

  @doc "The hourly scans."
  @spec hourly(DateTime.t()) :: map()
  def hourly(%DateTime{} = now) do
    for {name, fun} <- [
          invitations: &invitations/1,
          untouched: &untouched/1,
          triage_stale: &triage_stale/1,
          forwarding_silent: &forwarding_silent/1,
          purge_soon: &purge_soon/1,
          watch_ending: &watch_ending/1,
          system_checks: &system/1
        ],
        into: %{},
        do: {name, fun.(now)}
  end

  # ── The week (QP10b-13) ─────────────────────────────────────────────────────

  @doc "The weekly summary and the weekly report: `Core.Notifications.Weekly.run/1`."
  @spec weekly(DateTime.t()) :: map()
  def weekly(%DateTime{} = now), do: Weekly.run(now)

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  # ── Invitations (A2, A4) ────────────────────────────────────────────────────

  @doc """
  The invitee reminded three days on and the day before expiry (once each
  per issue, `Core.Mail.enqueue_once!/1`); the inviter told of an
  invitation that expired unused in the last 30 days.
  """
  @spec invitations(DateTime.t()) :: map()
  def invitations(%DateTime{} = now) do
    reminded =
      for i <- Store.open_invitations(now),
          {:remind, which} <- [reminder(i, now)] do
        Core.Mail.enqueue_once!(%{
          kind: :invitation_reminder,
          subject_id: i.id,
          options: %{when: which, expires_at: DateTime.to_iso8601(i.expires_at)}
        })
      end

    expired =
      for i <- Store.expired_invitations(DateTime.add(now, -30 * @day), now),
          do: Notifications.Account.invitation_expired(i, now)

    :ok = Notifications.send_events(expired)
    %{reminded: length(reminded), told: count(expired)}
  end

  @doc """
  Which reminder an open invitation is due at `now`: the day before it
  expires wins over three days on.

      iex> Core.Notifications.Scans.reminder(%{inserted_at: ~U[2026-11-01 10:00:00Z], expires_at: ~U[2026-11-08 10:00:00Z]}, ~U[2026-11-07 12:00:00Z])
      {:remind, "last_day"}
      iex> Core.Notifications.Scans.reminder(%{inserted_at: ~U[2026-11-01 10:00:00Z], expires_at: ~U[2026-11-08 10:00:00Z]}, ~U[2026-11-04 12:00:00Z])
      {:remind, "three_days"}
      iex> Core.Notifications.Scans.reminder(%{inserted_at: ~U[2026-11-01 10:00:00Z], expires_at: ~U[2026-11-08 10:00:00Z]}, ~U[2026-11-02 12:00:00Z])
      :not_yet
  """
  @spec reminder(map(), DateTime.t()) :: {:remind, String.t()} | :not_yet
  def reminder(invitation, %DateTime{} = now) do
    issued = issued_at(invitation)

    cond do
      DateTime.diff(invitation.expires_at, now) <= @day -> {:remind, "last_day"}
      DateTime.diff(now, issued) >= 3 * @day -> {:remind, "three_days"}
      true -> :not_yet
    end
  end

  # A resend gives a fresh week: the issue is seven days before expiry.
  defp issued_at(invitation) do
    later =
      DateTime.add(invitation.expires_at, -Invitations.ttl_days() * @day)

    if DateTime.after?(later, invitation.inserted_at), do: later, else: invitation.inserted_at
  end

  # ── Leads (L11, R2) ─────────────────────────────────────────────────────────

  @doc "To do leads untouched 7 days (and less than 30): each owner once per quiet stretch."
  @spec untouched(DateTime.t()) :: map()
  def untouched(%DateTime{} = now) do
    told =
      for lead <-
            Store.untouched_leads(DateTime.add(now, -30 * @day), DateTime.add(now, -7 * @day)) do
        touched = lead.last_activity_at || lead.inserted_at

        tell_lead(lead, lead.owner_user_id, "leads.untouched", now,
          title: "#{LeadWords.job(lead.job)} has sat in To do for a week",
          body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
          dedupe: "lead:#{lead.id}:untouched:#{DateTime.to_iso8601(touched)}"
        )
      end

    finish(told)
  end

  @doc "Archived leads purged within 7 days: the owner and the team's leads, once per archive."
  @spec purge_soon(DateTime.t()) :: map()
  def purge_soon(%DateTime{} = now) do
    told =
      for org <- Data.Retention.list_organisations_for_system(),
          settings = Data.Organisations.get_settings(org.id),
          days = settings.purge_after_days,
          lead <- Data.Retention.archived_leads(org.id, DateTime.add(now, (7 - days) * @day)),
          DateTime.after?(lead.archived_at, DateTime.add(now, -days * @day)),
          user_id <- purge_people(lead) do
        on = lead.archived_at |> DateTime.add(days * @day) |> Calendar.strftime("%-d %b")

        tell_lead(lead, user_id, "leads.purge_soon", now,
          title: "#{LeadWords.job(lead.job)} will be cleared on #{on}",
          body: "Unarchive it before then to keep it.",
          dedupe: "lead:#{lead.id}:purge_soon:#{DateTime.to_iso8601(lead.archived_at)}"
        )
      end

    finish(told)
  end

  defp purge_people(lead) do
    leads = for m <- Teams.list_members(lead.job.team_id), m.role == :lead, do: m.user_id
    Enum.uniq(Enum.reject([lead.owner_user_id | leads], &is_nil/1))
  end

  # ── Conversations (C4, C6) ──────────────────────────────────────────────────

  @doc "Triage items unresolved 48 hours (made in the last 30 days): the team's leads, once each."
  @spec triage_stale(DateTime.t()) :: map()
  def triage_stale(%DateTime{} = now) do
    told =
      for c <- Store.stale_triage(DateTime.add(now, -30 * @day), DateTime.add(now, -2 * @day)),
          m <- Teams.list_members(c.team_id),
          m.role == :lead do
        about = if c.subject, do: ": " <> c.subject, else: ""

        tell(c.organisation_id, m.user_id, "conversations.triage_stale", now,
          title: "Waiting in Triage for 2 days#{about}",
          body: "Link it to a lead, or ignore it.",
          link: "/triage?team=#{c.team_id}",
          dedupe: "conversation:#{c.id}:triage_stale"
        )
      end

    finish(told)
  end

  @doc """
  Forwarding addresses silent 14 days (and less than 60) after they had
  mail: the profiles' owners and the customer, once per silence.
  """
  @spec forwarding_silent(DateTime.t()) :: map()
  def forwarding_silent(%DateTime{} = now) do
    told =
      for {channel, last} <-
            Store.silent_channels(DateTime.add(now, -60 * @day), DateTime.add(now, -14 * @day)) do
        customer = channel.customer
        dedupe = "channel:#{channel.id}:silent:#{DateTime.to_iso8601(last)}"
        since = Calendar.strftime(last, "%-d %b")

        staff =
          for user_id <- Store.channel_owners(channel) do
            tell(customer.organisation_id, user_id, "conversations.forwarding_silent", now,
              title:
                "No mail from #{customer.display_name}'s #{channel.label || "Gmail"} since #{since}",
              body: "Check that Gmail still forwards to #{customer.display_name}'s address.",
              link: "/customers/#{customer.id}",
              dedupe: dedupe
            )
          end

        mine =
          if customer.user_id,
            do:
              tell(
                customer.organisation_id,
                customer.user_id,
                "conversations.forwarding_silent",
                now,
                title: "No mail has reached your team since #{since}",
                body: "Check that your Gmail still forwards to your team's address.",
                link: "/channels",
                dedupe: dedupe
              ),
            else: []

        [staff, mine]
      end

    finish(told)
  end

  # ── Behaviour (B2) ──────────────────────────────────────────────────────────

  @doc "Watches expiring within a day: each watcher, once per expiry."
  @spec watch_ending(DateTime.t()) :: map()
  def watch_ending(%DateTime{} = now) do
    told =
      now
      |> Data.Watches.expiring_for_system(DateTime.add(now, @day))
      |> Core.Watches.ending(:expiring, now)

    finish(told)
  end

  # ── Meetings (M5, M6) ───────────────────────────────────────────────────────

  @doc "Proposed meetings starting within 24 h, and meetings with no outcome 30 minutes after their end."
  @spec meetings(DateTime.t()) :: map()
  def meetings(%DateTime{} = now) do
    unconfirmed =
      for m <- Store.unconfirmed_meetings(now, DateTime.add(now, @day)),
          user_id <- unconfirmed_people(m) do
        tell_meeting(m, user_id, "meetings.unconfirmed", now,
          title:
            "#{about(m)} is still unconfirmed · #{MeetingWords.at(m.starts_at, zone(user_id))}",
          body: "Confirm it or dismiss it on the lead.",
          dedupe: "meeting:#{m.id}:unconfirmed:#{DateTime.to_iso8601(m.starts_at)}"
        )
      end

    outcome =
      for m <-
            Store.meetings_without_outcome(
              DateTime.add(now, -7 * @day),
              DateTime.add(now, -30 * 60)
            ),
          m.lead.owner_user_id do
        tell_meeting(m, m.lead.owner_user_id, "meetings.log_outcome", now,
          title: "How did #{about(m)} go?",
          body: "Mark it done or a no-show, and move the lead.",
          dedupe: "meeting:#{m.id}:log_outcome"
        )
      end

    finish(unconfirmed ++ outcome)
  end

  defp unconfirmed_people(m) do
    leads = for t <- Teams.list_members(m.lead.job.team_id), t.role == :lead, do: t.user_id
    Enum.uniq(Enum.reject([m.lead.owner_user_id | leads], &is_nil/1))
  end

  defp about(m) do
    case m.lead.job.company do
      %{name: name} -> "#{m.title} with #{name}"
      _none -> m.title
    end
  end

  defp zone(user_id) do
    case Data.Accounts.get_user(user_id) do
      %{person: %{timezone: zone}} -> zone
      _other -> "Etc/UTC"
    end
  end

  # ── The system admin's checks (S1–S3, E3) ───────────────────────────────────

  @doc "The hour's checks, each told to every organisation's system admin once per hour (or day)."
  @spec system(DateTime.t()) :: map()
  def system(%DateTime{} = now) do
    admins = Store.admins()
    hour = Calendar.strftime(now, "%Y-%m-%dT%H")
    since = DateTime.add(now, -@hour)
    day = DateTime.to_date(now)

    selectors =
      for {org, site, n} <- Store.misses_on(day),
          n > @selector_threshold,
          {^org, admin} <- admins do
        tell(org, admin, "system.selectors_failing", now,
          title: "#{site_name(site)}'s selectors missed #{n} times today",
          body: "#{site_name(site)} may have changed its pages. Check the extension's health.",
          link: "/settings/extension",
          dedupe: "system:selectors:#{site}:#{day}"
        )
      end

    deliveries =
      for {org, n} <- Store.delivery_failures(since),
          n > @delivery_threshold,
          {^org, admin} <- admins do
        tell(org, admin, "system.delivery_failing", now,
          title: "#{n} deliveries failed in the last hour",
          link: "/settings/system",
          dedupe: "system:delivery:#{hour}"
        )
      end

    inbound_n = Store.inbound_failures(since)

    inbound =
      for {org, admin} <- admins, inbound_n > @inbound_threshold do
        tell(org, admin, "system.inbound_failing", now,
          title: "#{inbound_n} forwarded mails failed in the last hour",
          link: "/settings/system",
          dedupe: "system:inbound:#{hour}"
        )
      end

    discarded = Store.discarded_jobs(since)

    jobs =
      for {org, admin} <- admins, discarded != [] do
        workers = discarded |> Enum.uniq() |> Enum.map_join(", ", &short_worker/1)

        tell(org, admin, "system.jobs_discarded", now,
          title: "#{plural(length(discarded), "background job")} gave up in the last hour",
          body: workers,
          link: "/settings/system",
          dedupe: "system:jobs:#{hour}"
        )
      end

    finish(selectors ++ deliveries ++ inbound ++ jobs)
  end

  defp site_name(:linkedin), do: "LinkedIn"
  defp site_name(:upwork), do: "Upwork"
  defp site_name(site), do: to_string(site)

  defp short_worker(worker), do: worker |> String.split(".") |> List.last()

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp finish(told) do
    :ok = Notifications.send_events(told)
    %{told: count(told)}
  end

  defp count(events), do: events |> List.flatten() |> length()

  defp tell_lead(lead, user_id, kind, now, opts) do
    tell(
      lead.organisation_id,
      user_id,
      kind,
      now,
      Keyword.merge(opts, lead_id: lead.id, link: "/leads/#{lead.id}")
    )
  end

  defp tell_meeting(m, user_id, kind, now, opts) do
    tell(
      m.organisation_id,
      user_id,
      kind,
      now,
      Keyword.merge(opts, lead_id: m.lead_id, link: "/leads/#{m.lead_id}")
    )
  end

  defp tell(nil, _user_id, _kind, _now, _opts), do: []
  defp tell(_org, nil, _kind, _now, _opts), do: []

  defp tell(organisation_id, user_id, kind, now, opts) do
    {:ok, row} =
      Notifications.ensure(
        Scope.system(%{id: organisation_id}),
        %{
          organisation_id: organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          lead_id: opts[:lead_id],
          title: opts[:title],
          body: opts[:body],
          link_path: opts[:link],
          dedupe_key: opts[:dedupe]
        },
        now
      )

    if row.is_new,
      do: [Core.Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
