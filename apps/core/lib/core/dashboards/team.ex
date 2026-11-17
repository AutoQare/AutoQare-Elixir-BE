defmodule Core.Dashboards.Team do
  @moduledoc """
  *Team* (AQ-11 §3.2, §3.3, §7.4): `GET /team/v1/dashboard/team?team_id&
  period&cohort` and its CSV, for a team's leads and the system admin
  (`team_id=all`: every team); anyone else finds nothing (404).

  | Part | Is |
  |---|---|
  | `members` | each open member, in name order: applications `today` and in the `period` (theirs, in this team's leads), `target_today` (§5), `responses` on those, `interviews` (leads they own here), `triage` (items on their profiles); with *All teams*, each staff member once over every team, their own target |
  | `funnel` | the cohort's *Applied → Responded → Interview → Offer → Hired* (`Core.Dashboards.funnel/3`), purged leads included |
  | `rates` | response rate by profile, platform and skill in the period (a lead counts under each of its job's skills) |
  | `stuck` · `overrides` · `admin` | `Core.Dashboards.Watch` |

  Without `team_id` the system admin reads *All teams* and a team lead
  their first team by name. The CSV is the members table, a blank line,
  then the funnel (QP11-17).
  """

  alias Core.Access
  alias Core.Dashboards
  alias Core.Dashboards.{Rates, Targets, Watch, Windows}
  alias Core.Leads
  alias Data.Dashboards.Rows
  alias Data.Scope
  alias Data.Teams

  @doc "*Team* at `now`."
  @spec build(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def build(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, reach} <- reach(scope, params["team_id"]),
         {:ok, key} <- Windows.period_key(params["period"]),
         {:ok, cohort} <- Windows.cohort_key(params["cohort"]) do
      {:ok, view(scope, reach, key, cohort, now)}
    end
  end

  @doc "The CSV of *Team* with the same filters: `{:ok, csv, filename}`."
  @spec csv(Scope.t(), map(), DateTime.t()) :: {:ok, iodata(), String.t()} | {:error, term()}
  def csv(%Scope{} = scope, params, %DateTime{} = now) do
    with {:ok, view} <- build(scope, params, now) do
      day = Windows.today(now, Dashboards.zone(scope))
      name = if view.team, do: slug(view.team.name), else: "all-teams"
      {:ok, csv_body(view), "dashboard-#{name}-#{day}.csv"}
    end
  end

  # ── Whose ───────────────────────────────────────────────────────────────────

  defp reach(scope, id) when id in [nil, ""] do
    led = for {team_id, :lead} <- scope.roles.teams, do: team_id

    cond do
      Scope.admin?(scope) ->
        reach(scope, "all")

      led != [] ->
        [team | _rest] = Teams.list(Scope.organisation_id(scope), ids: led)
        {:ok, team}

      true ->
        {:error, :not_found}
    end
  end

  defp reach(scope, "all") do
    with :ok <- Access.why_not(scope, :read, {:dashboard, :all}), do: {:ok, :all}
  end

  defp reach(scope, id) do
    with %{} = team <- Teams.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:dashboard, %{team_id: team.id}}),
         do: {:ok, team}
  end

  # ── The view ────────────────────────────────────────────────────────────────

  defp view(scope, reach, key, cohort_key, now) do
    zone = Dashboards.zone(scope)
    today = Windows.today(now, zone)
    period = Windows.period(key, now, zone)
    cohort = Windows.cohort(cohort_key, now, zone)
    window = {period.from, period.to}
    team_ids = team_ids(scope, reach)
    who = {:team, if(reach == :all, do: nil, else: team_ids)}

    %{
      period: Windows.json(period),
      team: if(reach == :all, do: nil, else: %{id: reach.id, name: reach.name}),
      members: members(scope, reach, team_ids, who, {today, window}, now),
      funnel: %{cohort: Windows.json(cohort), steps: Dashboards.funnel(scope, who, cohort)},
      rates: rates(scope, who, window),
      stuck: Watch.stuck(scope, who, today),
      overrides: Watch.overrides(scope, who, window),
      admin: if(Scope.admin?(scope), do: Watch.admin(scope, team_ids(reach), today, now))
    }
  end

  defp team_ids(_scope, %{id: id}), do: [id]

  defp team_ids(scope, :all),
    do: scope |> Scope.organisation_id() |> Teams.list() |> Enum.map(& &1.id)

  defp team_ids(%{id: id}), do: [id]
  defp team_ids(:all), do: nil

  # ── The members table ───────────────────────────────────────────────────────

  defp members(scope, reach, team_ids, who, {today, window}, now) do
    windows = %{today: Windows.day(today, Dashboards.zone(scope)), period: window}
    apps = scope |> Dashboards.applications(who, windows, :actor) |> Map.new(&{&1.group, &1})

    interviews =
      scope
      |> Dashboards.interviews(who, %{period: window}, :owner)
      |> Map.new(&{&1.group, &1.period})

    {triage, _total} = Dashboards.triage(scope, team_ids)

    for {user, target} <- people(scope, reach, today, now) do
      mine = Map.get(apps, user.id, %{today: %{count: 0}, period: %{count: 0, responses: 0}})

      %{
        user: Dashboards.person(user),
        today: mine.today.count,
        target_today: target,
        period_count: mine.period.count,
        responses: Rates.of(mine.period.responses, mine.period.count),
        interviews: Map.get(interviews, user.id, 0),
        triage: Map.get(triage, user.id, 0)
      }
    end
  end

  # `[{user, target_today}]` in name order.
  defp people(scope, %{id: team_id}, _today, now) do
    team_id
    |> Teams.list_members()
    |> then(&Dashboards.with_targets(scope, &1, now))
    |> Enum.map(&{&1.user, &1.target_today})
    |> by_name()
  end

  defp people(scope, :all, today, _now) do
    days = Dashboards.working_days(scope)
    memberships = scope |> team_ids(:all) |> Teams.memberships_in() |> Enum.group_by(& &1.user_id)
    owned = Dashboards.owned(Map.keys(memberships))

    memberships
    |> Enum.map(fn {user_id, [m | _rest] = ms} ->
      target = Targets.person(ms, Map.get(owned, user_id, []))
      {m.user, Targets.on(target, today, days)}
    end)
    |> by_name()
  end

  defp by_name(rows),
    do: Enum.sort_by(rows, fn {u, _t} -> {String.downcase(u.person.display_name), u.id} end)

  # ── Rates ───────────────────────────────────────────────────────────────────

  defp rates(scope, who, window) do
    by = &Dashboards.applications(scope, who, %{period: window}, &1)
    profiles = by.(:profile)
    skills = by.(:skill)
    titles = profiles |> Enum.map(& &1.group) |> Rows.profiles()
    names = skills |> Enum.map(& &1.group) |> Rows.skill_names()

    %{
      by_profile:
        rated(profiles, fn id -> titles[id] && %{profile: %{id: id, title: titles[id].title}} end),
      by_platform: rated(by.(:platform), &%{platform: &1}),
      by_skill: rated(skills, fn id -> names[id] && %{skill: %{id: id, name: names[id]}} end)
    }
  end

  defp rated(rows, label) do
    for %{group: group, period: %{count: n, responses: r}} <- rows,
        n > 0,
        head = label.(group),
        head do
      Map.merge(head, %{count: n, responses: r, rate_bp: Rates.rate_bp(r, n), few: Rates.few?(n)})
    end
    |> Enum.sort_by(&{-&1.count, sort_name(&1)})
  end

  defp sort_name(%{profile: %{title: t}}), do: t
  defp sort_name(%{skill: %{name: n}}), do: n
  defp sort_name(%{platform: p}), do: to_string(p)

  # ── The CSV ─────────────────────────────────────────────────────────────────

  defp csv_body(view) do
    head = [
      "Member",
      "Applications today",
      "Target today",
      "Applications (#{view.period.label})",
      "Responses",
      "Response rate",
      "Interviews",
      "Triage"
    ]

    members =
      Enum.map(view.members, fn m ->
        [
          m.user.name,
          m.today,
          m.target_today,
          m.period_count,
          m.responses.count,
          percent(m.responses.rate_bp),
          m.interviews,
          m.triage
        ]
      end)

    funnel =
      Enum.map(view.funnel.steps, &[step(&1.key), &1.count, percent(&1.rate_bp)])

    lines =
      [head | members] ++
        [[]] ++ [["Funnel: " <> view.funnel.cohort.label, "Count", "Rate"] | funnel]

    ["﻿" | Enum.map(lines, &line/1)]
  end

  defp step(key), do: key |> to_string() |> String.capitalize()

  defp percent(nil), do: nil
  defp percent(bp), do: :erlang.float_to_binary(bp / 100, decimals: 1) <> "%"

  defp line(cells), do: [Enum.map_join(cells, ",", &escape/1), "\r\n"]

  # RFC 4180 quoting; a cell a spreadsheet would read as a formula stays text.
  defp escape(nil), do: ""

  defp escape(value) do
    text = to_string(value)
    text = if String.starts_with?(text, ~w(= + - @)), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
