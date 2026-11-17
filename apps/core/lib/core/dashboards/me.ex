defmodule Core.Dashboards.Me do
  @moduledoc """
  *My numbers* (AQ-11 §3.1, §7.4): `GET /team/v1/dashboard/me?period`, any
  staff member's own. The period (*today · this week · this month*) moves
  the applications, responses, interviews and the bars; follow-ups,
  Triage, approvals and tasks are what is open now.

  | Part | Is |
  |---|---|
  | `target` | `today`: their target today (`nil` on a day off or with none, §5); `done_today`: their applications today; `run`: this week's working days to today, each `{on, done, target}` (the target as it stands now) |
  | `tiles` | `applications` · `responses` (on those applications, with the rate) · `interviews` (leads they own) · `follow_ups_due` (their In progress leads with a follow-up due, P4b) · `triage` (items on their profiles in their teams) · `approvals_waiting` (an open slot of theirs) · `tasks_due` (theirs, due today or overdue, not done) |
  | `by_profile` · `by_platform` | their applications in the period, most first |
  | `due_today` | follow-ups due, tasks due today or overdue, approvals due by tonight, today's meetings — one list, oldest first |
  | `upcoming_meetings` | scheduled, from now to the end of the seventh day ahead, on leads they own or with them attending |
  | `recent_applications` | their last 10 |
  | `about_to_archive` | leads they own that archive within 7 days |

  Every list shows only leads the caller may read.
  """

  alias Core.Access
  alias Core.Approvals
  alias Core.Dashboards
  alias Core.Dashboards.{Rates, Targets, Windows}
  alias Core.Leads
  alias Core.Leads.Signals
  alias Core.Retention.Policy
  alias Core.Tasks.{Cards, Visibility}
  alias Data.Dashboards.Rows
  alias Data.Scope

  @open_tasks [:todo, :in_progress, :on_hold]
  @recent 10

  @doc "*My numbers* at `now`."
  @spec build(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def build(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :read, {:dashboard, :me}),
         {:ok, key} <- Windows.period_key(params["period"]) do
      {:ok, numbers(scope, key, now)}
    end
  end

  defp numbers(scope, key, now) do
    me = Scope.user_id(scope)
    zone = Dashboards.zone(scope)
    days = Dashboards.working_days(scope)
    today = Windows.today(now, zone)
    period = Windows.period(key, now, zone)
    run_days = Windows.week_so_far(today, days)
    window = {period.from, period.to}

    windows =
      Map.merge(
        %{today: Windows.day(today, zone), period: window},
        Map.new(run_days, &{&1, Windows.day(&1, zone)})
      )

    apps = Dashboards.applications(scope, {:person, me}, windows)
    target = Dashboards.person_target(scope, me)
    follow_ups = follow_ups(scope, me, now)
    tasks = tasks_due(scope, me, today)
    approvals = Approvals.waiting(scope)
    {triage, _total} = Dashboards.triage(scope, Scope.team_ids(scope))

    %{
      period: Windows.json(period),
      person: Dashboards.person(scope.user),
      target: %{
        today: Targets.on(target, today, days),
        done_today: apps.today.count,
        run: Enum.map(run_days, &%{on: &1, done: apps[&1].count, target: target})
      },
      tiles: %{
        applications: apps.period.count,
        responses: Rates.of(apps.period.responses, apps.period.count),
        interviews: Dashboards.interviews(scope, {:person, me}, %{period: window}).period,
        follow_ups_due: length(follow_ups),
        triage: Map.get(triage, me, 0),
        approvals_waiting: length(approvals),
        tasks_due: length(tasks)
      },
      by_profile: by_profile(scope, me, window),
      by_platform: by_platform(scope, me, window),
      due_today: due_today(scope, {follow_ups, tasks, approvals}, today, zone),
      upcoming_meetings:
        scope
        |> meetings(me, {now, Windows.start_of(Date.add(today, 8), zone)})
        |> Enum.map(&meeting/1),
      recent_applications: recent(scope, me),
      about_to_archive: about_to_archive(scope, me, today, now, zone)
    }
  end

  # ── The bars ────────────────────────────────────────────────────────────────

  defp by_profile(scope, me, window) do
    rows = Dashboards.applications(scope, {:person, me}, %{period: window}, :profile)
    profiles = rows |> Enum.map(& &1.group) |> Rows.profiles()

    for %{group: id, period: %{count: n}} <- rows,
        n > 0,
        p = profiles[id],
        p do
      %{
        profile: %{
          id: p.id,
          title: p.title,
          customer: %{id: p.customer.id, display_name: p.customer.display_name}
        },
        count: n
      }
    end
    |> Enum.sort_by(&{-&1.count, &1.profile.title})
  end

  defp by_platform(scope, me, window) do
    for(
      %{group: platform, period: %{count: n}} <-
        Dashboards.applications(scope, {:person, me}, %{period: window}, :platform),
      n > 0,
      do: %{platform: platform, count: n}
    )
    |> Enum.sort_by(&{-&1.count, to_string(&1.platform)})
  end

  # ── What is open now ────────────────────────────────────────────────────────

  # Their In progress leads with a follow-up due (P4b's rule): `[{lead, follow_up}]`.
  defp follow_ups(scope, me, now) do
    leads =
      scope
      |> Dashboards.lead_subject({:person, me})
      |> Rows.leads(states: [:in_progress], live: true)
      |> readable(scope)

    ctx = Signals.context(scope.organisation, leads, now)

    for lead <- leads,
        follow_up = Signals.follow_up(ctx, lead),
        follow_up.state == :due,
        do: {lead, follow_up}
  end

  defp tasks_due(scope, me, today) do
    tomorrow = Windows.start_of(Date.add(today, 1), Dashboards.zone(scope))

    scope
    |> Visibility.filter()
    |> Data.Tasks.list(view: [{:mine, me}])
    |> Enum.filter(
      &(Cards.mine?(&1, me) and &1.state in @open_tasks and due_by?(&1, today, tomorrow))
    )
  end

  defp due_by?(%{due_at: %DateTime{} = at}, _today, tomorrow), do: DateTime.before?(at, tomorrow)
  defp due_by?(%{due_on: %Date{} = on}, today, _tomorrow), do: Date.compare(on, today) != :gt
  defp due_by?(_task, _today, _tomorrow), do: false

  # ── Due today ───────────────────────────────────────────────────────────────

  defp due_today(scope, {follow_ups, tasks, approvals}, today, zone) do
    me = Scope.user_id(scope)
    tomorrow = Windows.start_of(Date.add(today, 1), zone)

    items =
      Enum.map(follow_ups, &follow_up_item/1) ++
        Enum.map(tasks, &task_item(&1, today, zone)) ++
        for(
          a <- approvals,
          a.due_at && DateTime.before?(a.due_at, tomorrow),
          do: approval_item(a)
        ) ++
        Enum.map(meetings(scope, me, Windows.day(today, zone)), &meeting_item/1)

    Enum.sort_by(items, & &1.at, DateTime)
  end

  defp follow_up_item({lead, f}) do
    %{
      kind: "follow_up",
      id: lead.id,
      title: Dashboards.lead_title(lead),
      line:
        "Follow-up #{f.number} of #{f.of} · #{lead.profile.customer.display_name} · " <>
          lead.profile.title,
      at: f.since,
      link_path: "/leads/#{lead.id}"
    }
  end

  defp task_item(task, today, zone) do
    at = task.due_at || Windows.start_of(task.due_on, zone)
    overdue? = if task.due_on, do: Date.before?(task.due_on, today), else: false

    %{
      kind: "task",
      id: task.id,
      title: task.title,
      line:
        if(overdue?,
          do: "Overdue since #{Calendar.strftime(task.due_on, "%-d %b")}",
          else: "Due today"
        ),
      at: at,
      link_path: "/board/#{task.id}"
    }
  end

  defp approval_item(a) do
    %{
      kind: "approval",
      id: a.id,
      title: a.title,
      line: "Waiting on you · #{a.customer.display_name}",
      at: a.due_at,
      link_path: "/approvals/#{a.id}"
    }
  end

  defp meeting_item(m) do
    %{
      kind: "meeting",
      id: m.id,
      title: m.title,
      line: Dashboards.lead_title(m.lead),
      at: m.starts_at,
      link_path: "/leads/#{m.lead_id}"
    }
  end

  # ── The lists ───────────────────────────────────────────────────────────────

  defp meetings(scope, me, window) do
    scope
    |> Dashboards.lead_subject({:person, me})
    |> Rows.meetings(window, attendee_user_id: me)
    |> Enum.filter(&Access.can?(scope, :read, {:lead, Leads.subject(&1.lead)}))
  end

  defp meeting(m) do
    %{
      id: m.id,
      title: m.title,
      starts_at: m.starts_at,
      ends_at: m.ends_at,
      time_zone: m.time_zone,
      lead: m.lead && %{id: m.lead.id, title: Dashboards.lead_title(m.lead)}
    }
  end

  defp recent(scope, me) do
    rows = Rows.applied_rows(Dashboards.applied_subject(scope, {:person, me}), limit: @recent)

    leads =
      scope
      |> Dashboards.lead_subject({:team, nil})
      |> Rows.leads(ids: Enum.map(rows, & &1.lead_id))
      |> readable(scope)
      |> Map.new(&{&1.id, &1})

    for e <- rows, lead = leads[e.lead_id], lead do
      %{
        lead_id: lead.id,
        title: lead.job.title,
        company: Dashboards.company(lead),
        profile: %{id: lead.profile.id, title: lead.profile.title},
        applied_at: e.occurred_at,
        state: lead.state,
        stage: lead.stage && %{key: lead.stage.key, label: lead.stage.name}
      }
    end
  end

  defp about_to_archive(scope, me, today, now, zone) do
    settings = Signals.settings(Scope.organisation_id(scope))

    for lead <-
          scope
          |> Dashboards.lead_subject({:person, me})
          |> Rows.leads(live: true)
          |> readable(scope),
        not lead.is_pinned,
        on = Policy.quiet(lead, settings, now, zone).archives_on,
        on && Date.diff(on, today) <= 7 do
      %{
        lead_id: lead.id,
        title: lead.job.title,
        company: Dashboards.company(lead),
        archives_on: on
      }
    end
    |> Enum.sort_by(& &1.archives_on, Date)
  end

  defp readable(leads, scope),
    do: Enum.filter(leads, &Access.can?(scope, :read, {:lead, Leads.subject(&1)}))
end
