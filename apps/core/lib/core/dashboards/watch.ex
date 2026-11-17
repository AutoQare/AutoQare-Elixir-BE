defmodule Core.Dashboards.Watch do
  @moduledoc """
  What a team lead watches on *Team* (AQ-11 §3.2, §3.3, §4), each list cut
  to the leads the caller reads:

  - **Stuck**: leads quiet 30 to 59 days (`quiet_30`) and 60 days or more
    (`quiet_60`) by P4b's quiet clock (`Core.Retention.Policy`), counted
    in the organisation's days — not archived, not held, and not finished
    (a Done lead isn't stuck, it's over); the quietest first.
  - **Overrides**: the period's *Apply again*, with who and why.
  - **The system admin's** (`admin`): what archives and what purges in the
    next 7 days (the retention policy's own days) and, per site, the
    extension's misses over 7 days and its last capture
    (`Core.Extension.Health`).

  A *lead row* is `{lead_id, title, company, owner: {id, name}?,
  quiet_days}`.
  """

  alias Core.Access
  alias Core.Dashboards
  alias Core.Dashboards.Windows
  alias Core.Extension.Health
  alias Core.Leads
  alias Core.Leads.Signals
  alias Core.Retention.Policy
  alias Data.Dashboards.Rows
  alias Data.Scope

  @soon_days 7

  @doc "`%{quiet_30, quiet_60}` for `who` on `today`."
  @spec stuck(Scope.t(), Dashboards.who(), Date.t()) :: map()
  def stuck(%Scope{} = scope, who, %Date{} = today) do
    zone = Dashboards.zone(scope)

    rows =
      for lead <-
            scope
            |> Dashboards.lead_subject(who)
            |> Rows.leads(
              states: [:todo, :in_progress],
              live: true,
              quiet_before: Windows.start_of(Date.add(today, -29), zone)
            )
            |> readable(scope),
          days = quiet_days(lead, today, zone),
          days >= 30,
          do: row(lead, days)

    {sixty, thirty} = Enum.split_with(rows, &(&1.quiet_days >= 60))
    %{quiet_30: quietest(thirty), quiet_60: quietest(sixty)}
  end

  @doc "The period's *Apply again*: `[{lead_id, title, by: {id, name}, at, reason}]`, newest first."
  @spec overrides(Scope.t(), Dashboards.who(), Windows.window()) :: [map()]
  def overrides(%Scope{} = scope, who, window) do
    events =
      scope
      |> Dashboards.applied_subject(who)
      |> Rows.applied_rows(window: window, again: true)

    leads = leads_by_id(scope, Enum.map(events, & &1.lead_id))

    for e <- events, lead = leads[e.lead_id], lead do
      %{
        lead_id: lead.id,
        title: Dashboards.lead_title(lead),
        by: Dashboards.person(e.actor_user),
        at: e.occurred_at,
        reason: e.note
      }
    end
  end

  @doc """
  The system admin's part: `%{retention: %{archive_next, purge_next},
  extension: [{site, misses_7d, last_capture_at}]}` for `team_ids` (nil:
  every team).
  """
  @spec admin(Scope.t(), [binary()] | nil, Date.t(), DateTime.t()) :: map()
  def admin(%Scope{} = scope, team_ids, %Date{} = today, %DateTime{} = now) do
    org = Scope.organisation_id(scope)
    zone = Dashboards.zone(scope)
    settings = Signals.settings(org)
    soon = &(Date.diff(&1, today) <= @soon_days)

    # Candidates by date, a day to spare; the policy's own days decide.
    archive_cutoff =
      Windows.start_of(Date.add(today, @soon_days + 2 - settings.inactivity_days), zone)

    purge_cutoff =
      Windows.start_of(Date.add(today, @soon_days + 2 - settings.purge_after_days), zone)

    archive_next =
      for lead <- Data.Retention.quiet_leads(org, archive_cutoff, team_ids) |> readable(scope),
          on = Policy.day(Policy.archive_at(lead, settings, zone), zone),
          soon.(on),
          do: row(lead, quiet_days(lead, today, zone))

    purge_next =
      for lead <- Data.Retention.archived_leads(org, purge_cutoff, team_ids) |> readable(scope),
          on = Policy.purges_on(lead, settings, zone),
          on && soon.(on),
          do: row(lead, quiet_days(lead, today, zone))

    %{
      retention: %{archive_next: archive_next, purge_next: purge_next},
      extension: extension(scope, now)
    }
  end

  defp extension(scope, now) do
    {:ok, %{sites: sites}} = Health.page(scope, now)

    for s <- sites do
      %{
        site: s.site,
        misses_7d: s.misses |> Enum.map(& &1.count) |> Enum.sum(),
        last_capture_at: s.last_capture_at
      }
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp row(lead, days) do
    %{
      lead_id: lead.id,
      title: lead.job.title,
      company: Dashboards.company(lead),
      owner: Dashboards.person(lead.owner_user),
      quiet_days: days
    }
  end

  defp quiet_days(lead, today, zone),
    do: Date.diff(today, Policy.day(Policy.quiet_since(lead, zone), zone))

  defp quietest(rows), do: Enum.sort_by(rows, &{-&1.quiet_days, &1.title})

  defp leads_by_id(scope, ids) do
    scope
    |> Dashboards.lead_subject({:team, nil})
    |> Rows.leads(ids: ids)
    |> readable(scope)
    |> Map.new(&{&1.id, &1})
  end

  defp readable(leads, scope),
    do: Enum.filter(leads, &Access.can?(scope, :read, {:lead, Leads.subject(&1)}))
end
