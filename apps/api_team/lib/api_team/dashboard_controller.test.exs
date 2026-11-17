defmodule ApiTeam.DashboardControllerTest do
  @moduledoc """
  AQ-11 §7.4 over HTTP: `GET /dashboard/me`, `GET /dashboard/team` and its
  CSV — each shape's **exact keys**, the 404 for whoever may not ask, the
  422 for a period or cohort off the list.
  """

  use ApiTeam.TeamCase, async: true

  alias Core.Clock
  alias Core.Leads.Act

  # Thursday 12 Nov 2026, 12:00 in Karachi.
  @now ~U[2026-11-12 07:00:00.000000Z]

  @me ~w(about_to_archive by_platform by_profile due_today period person recent_applications
         target tiles upcoming_meetings)
  @period ~w(from key label to)
  @target ~w(done_today run today)
  @tiles ~w(applications approvals_waiting follow_ups_due interviews responses tasks_due triage)
  @rate ~w(count few of rate_bp)
  @due ~w(at id kind line link_path title)
  @meeting ~w(ends_at id lead starts_at time_zone title)
  @recent ~w(applied_at company lead_id profile stage state title)
  @team ~w(admin funnel members overrides period rates stuck team)
  @member ~w(interviews period_count responses target_today today triage user)
  @rated ~w(count few rate_bp responses)
  @lead_row ~w(company lead_id owner quiet_days title)

  setup do
    on_exit(&Clock.unfreeze/0)
    Clock.freeze(@now)
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    go = skill_fixture(c.org, name: "Go")
    job = job_fixture(fs, team: c.backend, title: "Go Engineer", skills: [{go, true}])

    {:ok, lead} =
      Core.Leads.create(fs, %{job_id: job.id, profile_id: c.golang.id, as: "apply"}, @now)

    lead = Data.Leads.get(c.org.id, lead.id)
    meeting_fixture(fs, lead: lead, starts_at: ~U[2026-11-12 10:00:00.000000Z])
    task_fixture(fs, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-12])

    {:ok, _} =
      Act.run(
        fs,
        :apply_again,
        lead.id,
        %{from: %{state: "in_progress", stage: "applied"}, reason: "New CV"},
        @now
      )

    lead_fixture(fs,
      team: c.backend,
      profile: c.golang,
      last_activity_at: ~U[2026-08-19 07:00:00.000000Z]
    )

    Map.put(c, :lead, lead)
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "GET /dashboard/me: the shape, exactly", c do
    conn = call(c.fiza, :get, "/v1/dashboard/me?period=week")
    assert conn.status == 200
    me = body(conn)

    assert keys(me) == @me
    assert keys(me["period"]) == @period

    assert me["period"] == %{
             "key" => "week",
             "from" => "2026-11-09",
             "to" => "2026-11-15",
             "label" => "This week"
           }

    assert keys(me["person"]) == ~w(id name)
    assert keys(me["target"]) == @target
    assert [%{"on" => "2026-11-09"} = run | _rest] = me["target"]["run"]
    assert keys(run) == ~w(done on target)
    assert keys(me["tiles"]) == @tiles
    assert keys(me["tiles"]["responses"]) == @rate
    assert me["tiles"]["applications"] == 2

    assert [by_profile] = me["by_profile"]
    assert keys(by_profile) == ~w(count profile)
    assert keys(by_profile["profile"]) == ~w(customer id title)
    assert keys(by_profile["profile"]["customer"]) == ~w(display_name id)
    assert [%{"platform" => "company_site", "count" => 2} = platform] = me["by_platform"]
    assert keys(platform) == ~w(count platform)

    assert [task, meeting] = me["due_today"]
    assert keys(task) == @due and keys(meeting) == @due
    assert {task["kind"], meeting["kind"]} == {"task", "meeting"}

    assert [upcoming] = me["upcoming_meetings"]
    assert keys(upcoming) == @meeting
    assert keys(upcoming["lead"]) == ~w(id title)

    assert [recent | _rest] = me["recent_applications"]
    assert keys(recent) == @recent
    assert keys(recent["profile"]) == ~w(id title)
    assert keys(recent["stage"]) == ~w(key label)

    assert [archiving] = me["about_to_archive"]
    assert keys(archiving) == ~w(archives_on company lead_id title)

    assert code(call(c.fiza, :get, "/v1/dashboard/me?period=year")) == "validation_failed"
  end

  test "GET /dashboard/team: the shape, exactly; admin only for the system admin", c do
    path = "/v1/dashboard/team?team_id=#{c.backend.id}&period=week&cohort=this_month"
    conn = call(c.hira, :get, path)
    assert conn.status == 200
    team = body(conn)

    assert keys(team) == @team
    assert team["team"] == %{"id" => c.backend.id, "name" => "Backend squad"}
    assert team["admin"] == nil
    assert keys(team["period"]) == @period

    assert [member | _rest] = team["members"]
    assert keys(member) == @member
    assert keys(member["user"]) == ~w(id name)
    assert keys(member["responses"]) == @rate

    assert keys(team["funnel"]) == ~w(cohort steps)
    assert keys(team["funnel"]["cohort"]) == @period

    assert Enum.map(team["funnel"]["steps"], & &1["key"]) ==
             ~w(applied responded interview offer hired)

    assert Enum.all?(team["funnel"]["steps"], &(keys(&1) == ~w(count key rate_bp)))

    assert keys(team["rates"]) == ~w(by_platform by_profile by_skill)
    assert [profile] = team["rates"]["by_profile"]
    assert keys(profile) == Enum.sort(["profile" | @rated])
    assert keys(profile["profile"]) == ~w(id title)
    assert [platform] = team["rates"]["by_platform"]
    assert keys(platform) == Enum.sort(["platform" | @rated])
    assert [skill] = team["rates"]["by_skill"]
    assert keys(skill) == Enum.sort(["skill" | @rated])
    assert keys(skill["skill"]) == ~w(id name)

    assert keys(team["stuck"]) == ~w(quiet_30 quiet_60)
    assert [stuck] = team["stuck"]["quiet_60"]
    assert keys(stuck) == @lead_row

    assert [override] = team["overrides"]
    assert keys(override) == ~w(at by lead_id reason title)
    assert keys(override["by"]) == ~w(id name)

    all = body(call(c.dawud, :get, "/v1/dashboard/team?team_id=all&period=today&cohort=last_90"))
    assert all["team"] == nil
    assert keys(all["admin"]) == ~w(extension retention)
    assert keys(all["admin"]["retention"]) == ~w(archive_next purge_next)
    assert [site | _rest] = all["admin"]["extension"]
    assert keys(site) == ~w(last_capture_at misses_7d site)
  end

  test "who may not ask finds nothing; a cohort off the list is a field error", c do
    path = "/v1/dashboard/team?team_id=#{c.backend.id}&period=week&cohort=this_month"
    assert call(c.fiza, :get, path).status == 404

    assert call(c.bilal, :get, "/v1/dashboard/team?team_id=all&period=week&cohort=this_month").status ==
             404

    assert call(c.hira, :get, "/v1/dashboard/team?team_id=#{Ecto.UUID.generate()}").status == 404

    bad = call(c.hira, :get, "/v1/dashboard/team?team_id=#{c.backend.id}&cohort=forever")
    assert bad.status == 422
    assert body(bad)["error"]["details"]["cohort"]
  end

  test "GET /dashboard/team.csv: the members table, a blank line, the funnel", c do
    conn =
      call(
        c.hira,
        :get,
        "/v1/dashboard/team.csv?team_id=#{c.backend.id}&period=week&cohort=this_month"
      )

    assert conn.status == 200
    assert ["text/csv; charset=utf-8"] = Plug.Conn.get_resp_header(conn, "content-type")

    assert [~s(attachment; filename="dashboard-backend-squad-2026-11-12.csv")] =
             Plug.Conn.get_resp_header(conn, "content-disposition")

    "﻿" <> text = conn.resp_body
    [table, funnel] = String.split(text, "\r\n\r\n")
    assert table =~ "Fiza,2,35,2,0,0.0%,1,0"
    assert funnel =~ "Applied,2,100.0%"
    assert call(c.fiza, :get, "/v1/dashboard/team.csv?team_id=#{c.backend.id}").status == 404
  end
end
