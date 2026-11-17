defmodule Core.Dashboards.TeamTest do
  @moduledoc """
  AQ-11 P11.3: *Team* against hand counts — the members table (it follows
  the period), the funnel by cohort with purged leads from their
  fingerprints, the rates by profile, platform and skill, stuck leads,
  overrides, the system admin's retention and extension, *All teams* as the
  sum of the teams, who may ask, and the CSV.
  """

  use Core.CoreCase, async: true

  alias Core.Dashboards

  # Thursday 12 Nov 2026, 12:00 in Karachi.
  @now ~U[2026-11-12 07:00:00.000000Z]

  defp days_ago(n), do: DateTime.add(@now, -n * 86_400, :second)

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    qs = scope_for(c.qasim)
    go = skill_fixture(c.org, name: "Go")
    pg = skill_fixture(c.org, name: "PostgreSQL")
    imran = profile_fixture(c.imran, title: "React", owners: [c.fiza], daily_target: 20)

    linkedin =
      job_fixture(fs,
        team: c.backend,
        title: "Go Engineer",
        url: "https://www.linkedin.com/jobs/view/4100000001",
        skills: [{go, true}, {pg, false}]
      )

    l1 = apply_at(fs, linkedin, c.golang, ~U[2026-11-09 05:00:00.000000Z])
    l2 = apply_at(fs, job_fixture(fs, team: c.backend), c.golang, ~U[2026-11-10 05:00:00.000000Z])
    l3 = apply_at(qs, job_fixture(qs, team: c.backend), c.golang, ~U[2026-11-11 05:00:00.000000Z])
    _l4 = apply_at(fs, job_fixture(fs, team: c.frontend), imran, ~U[2026-11-10 06:00:00.000000Z])

    verb_at(
      fs,
      :move,
      l1,
      %{"state" => "in_progress", "stage" => "technical_1"},
      ~U[2026-11-12 04:00:00.000000Z]
    )

    reply_at(fs, l2, ~U[2026-11-11 06:00:00.000000Z])
    verb_at(fs, :apply_again, l2, %{"reason" => "Better CV"}, ~U[2026-11-12 05:00:00.000000Z])

    l3 =
      verb_at(
        qs,
        :move,
        l3,
        %{"state" => "in_progress", "stage" => "offer"},
        ~U[2026-11-12 05:30:00.000000Z]
      )

    verb_at(qs, :finish, l3, %{"outcome" => "hired"}, ~U[2026-11-12 06:00:00.000000Z])

    # Purged: one this month, one last month.
    fingerprint_fixture(fs, linkedin, c.golang,
      applied_on: ~D[2026-11-03],
      stage_kinds: [:applied, :screening, :interview],
      outcome: :rejected
    )

    fingerprint_fixture(fs, linkedin, c.golang,
      applied_on: ~D[2026-10-20],
      stage_kinds: [:applied, :interview, :offer],
      outcome: :hired
    )

    Map.merge(c, %{fs: fs, l1: l1, l2: l2, l3: l3, imran: imran})
  end

  defp row(view, name), do: Enum.find(view.members, &(&1.user.name == name))

  test "the members table follows the period, in name order", c do
    {:ok, week} =
      Dashboards.team(scope_for(c.hira), %{"team_id" => c.backend.id, "period" => "week"}, @now)

    assert week.team == %{id: c.backend.id, name: "Backend squad"}

    assert Enum.map(week.members, & &1.user.name) == [
             "Bilal",
             "Fiza",
             "Hira Khan",
             "Muaz",
             "Qasim"
           ]

    # Fiza: Mon, Tue and today's apply again here (not her Frontend one).
    assert row(week, "Fiza") == %{
             user: %{id: c.fiza.id, name: "Fiza"},
             today: 1,
             target_today: 35,
             period_count: 3,
             responses: %{count: 2, of: 3, rate_bp: 6666, few: true},
             interviews: 1,
             triage: 0
           }

    # Qasim's lead reached an offer and was hired: a response, not an interview.
    assert %{period_count: 1, responses: %{count: 1, of: 1}, interviews: 0, target_today: 35} =
             row(week, "Qasim")

    assert %{period_count: 0, target_today: nil, responses: %{rate_bp: nil}} = row(week, "Muaz")

    {:ok, today} = Dashboards.team(scope_for(c.hira), %{"team_id" => c.backend.id}, @now)
    assert %{today: 1, period_count: 1} = row(today, "Fiza")
    assert %{period_count: 0} = row(today, "Qasim")
  end

  test "the funnel by cohort, purged leads counted from their fingerprints", c do
    hs = scope_for(c.hira)
    {:ok, team} = Dashboards.team(hs, %{"team_id" => c.backend.id}, @now)

    assert team.funnel.cohort == %{
             key: :this_month,
             from: ~D[2026-11-01],
             to: ~D[2026-11-30],
             label: "This month"
           }

    # Applied: L1, L2, L2 again, L3 and the purged one of 3 Nov.
    assert team.funnel.steps == [
             %{key: :applied, count: 5, rate_bp: 10_000},
             %{key: :responded, count: 4, rate_bp: 8000},
             %{key: :interview, count: 2, rate_bp: 5000},
             %{key: :offer, count: 1, rate_bp: 5000},
             %{key: :hired, count: 1, rate_bp: 10_000}
           ]

    {:ok, last} =
      Dashboards.team(hs, %{"team_id" => c.backend.id, "cohort" => "last_month"}, @now)

    assert Enum.map(last.funnel.steps, & &1.count) == [1, 1, 1, 1, 1]

    {:ok, ninety} = Dashboards.team(hs, %{"team_id" => c.backend.id, "cohort" => "last_90"}, @now)
    assert hd(ninety.funnel.steps).count == 6
  end

  test "response rates by profile, platform and skill", c do
    {:ok, team} =
      Dashboards.team(scope_for(c.hira), %{"team_id" => c.backend.id, "period" => "week"}, @now)

    assert team.rates.by_profile == [
             %{
               profile: %{id: c.golang.id, title: "Golang backend"},
               count: 4,
               responses: 3,
               rate_bp: 7500,
               few: true
             }
           ]

    assert team.rates.by_platform == [
             %{platform: :company_site, count: 3, responses: 2, rate_bp: 6666, few: true},
             %{platform: :linkedin, count: 1, responses: 1, rate_bp: 10_000, few: true}
           ]

    assert Enum.map(team.rates.by_skill, &{&1.skill.name, &1.count, &1.responses}) ==
             [{"Go", 1, 1}, {"PostgreSQL", 1, 1}]
  end

  test "stuck leads: quiet 30 and 60 days, not held, finished or archived; overrides", c do
    ms = scope_for(c.muaz)
    p = [team: c.backend, profile: c.golang]
    thirty = lead_fixture(ms, p ++ [as: :apply, last_activity_at: days_ago(45)])
    sixty = lead_fixture(ms, p ++ [last_activity_at: days_ago(70)])
    lead_fixture(ms, p ++ [state: :on_hold, last_activity_at: days_ago(80)])
    lead_fixture(ms, p ++ [state: :done, last_activity_at: days_ago(50)])
    lead_fixture(ms, p ++ [archived: true, last_activity_at: days_ago(50)])

    {:ok, team} =
      Dashboards.team(scope_for(c.hira), %{"team_id" => c.backend.id, "period" => "week"}, @now)

    assert [%{lead_id: id30, quiet_days: 45, owner: %{name: "Muaz"}}] = team.stuck.quiet_30
    assert [%{lead_id: id60, quiet_days: 70}] = team.stuck.quiet_60
    assert {id30, id60} == {thirty.id, sixty.id}

    assert [%{lead_id: id, by: %{name: "Fiza"}, reason: "Better CV"}] = team.overrides
    assert id == c.l2.id
  end

  test "who may ask: a team's leads, the system admin; All teams the sum of the teams", c do
    assert {:error, :not_found} = Dashboards.team(c.fs, %{"team_id" => c.backend.id}, @now)
    bs = scope_for(c.bilal)
    assert {:error, :not_found} = Dashboards.team(bs, %{"team_id" => c.frontend.id}, @now)
    assert {:error, :not_found} = Dashboards.team(bs, %{"team_id" => "all"}, @now)
    assert {:ok, %{team: %{id: id}, admin: nil}} = Dashboards.team(bs, %{}, @now)
    assert id == c.backend.id

    ds = scope_for(c.dawud)
    {:ok, all} = Dashboards.team(ds, %{"team_id" => "all", "period" => "week"}, @now)
    {:ok, back} = Dashboards.team(ds, %{"team_id" => c.backend.id, "period" => "week"}, @now)
    {:ok, front} = Dashboards.team(ds, %{"team_id" => c.frontend.id, "period" => "week"}, @now)

    assert all.team == nil
    sum = fn view -> Enum.map(view.funnel.steps, & &1.count) end
    assert sum.(all) == Enum.zip_with(sum.(back), sum.(front), &(&1 + &2))

    # Fiza once, over both teams; her own target (Golang 35 + React 20).
    assert %{period_count: 4, target_today: 55} = row(all, "Fiza")
    assert %{period_count: 1, target_today: 20} = row(front, "Fiza")
    assert %{retention: %{archive_next: [], purge_next: []}, extension: [_ | _]} = all.admin
  end

  test "the system admin's retention: what archives and purges in the next 7 days", c do
    ms = scope_for(c.muaz)
    soon = lead_fixture(ms, team: c.backend, profile: c.golang, last_activity_at: days_ago(85))
    lead_fixture(ms, team: c.backend, profile: c.golang, last_activity_at: days_ago(70))

    gone =
      lead_fixture(ms,
        team: c.backend,
        profile: c.golang,
        archived: true,
        archived_at: days_ago(88),
        last_activity_at: days_ago(178)
      )

    {:ok, all} = Dashboards.team(scope_for(c.dawud), %{"team_id" => "all"}, @now)
    assert [%{lead_id: a, quiet_days: 85}] = all.admin.retention.archive_next
    assert [%{lead_id: p}] = all.admin.retention.purge_next
    assert {a, p} == {soon.id, gone.id}
  end

  test "the CSV: the members table, a blank line, then the funnel", c do
    {:ok, csv, name} =
      Dashboards.team_csv(
        scope_for(c.hira),
        %{"team_id" => c.backend.id, "period" => "week"},
        @now
      )

    assert name == "dashboard-backend-squad-2026-11-12.csv"
    "﻿" <> text = IO.iodata_to_binary(csv)
    [table, funnel] = String.split(text, "\r\n\r\n")

    assert String.split(table, "\r\n") == [
             "Member,Applications today,Target today,Applications (This week),Responses,Response rate,Interviews,Triage",
             "Bilal,0,,0,0,,0,0",
             "Fiza,1,35,3,2,66.7%,1,0",
             "Hira Khan,0,,0,0,,0,0",
             "Muaz,0,,0,0,,0,0",
             "Qasim,0,35,1,1,100.0%,0,0"
           ]

    assert String.split(funnel, "\r\n", trim: true) == [
             "Funnel: This month,Count,Rate",
             "Applied,5,100.0%",
             "Responded,4,80.0%",
             "Interview,2,50.0%",
             "Offer,1,50.0%",
             "Hired,1,100.0%"
           ]

    assert {:error, :not_found} = Dashboards.team_csv(c.fs, %{"team_id" => c.backend.id}, @now)
  end
end
