defmodule Core.Dashboards.HomeTest do
  @moduledoc """
  AQ-11 P11.4: the customer's *Home* — their own profiles only, this week
  and last week as the tiles count them (their own *I applied* too), the
  pipeline by stage, what's next, and recent replies with the team's
  settings applied; staff find nothing.
  """

  use Core.CoreCase, async: true

  alias Core.Dashboards
  alias Core.Leads.Act

  # Thursday 12 Nov 2026, 12:00 in Karachi.
  @now ~U[2026-11-12 07:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    job = fn -> job_fixture(fs, team: c.backend, title: "Backend Developer") end

    la = apply_at(fs, job.(), c.golang, ~U[2026-11-10 05:00:00.000000Z])
    lb = apply_at(fs, job.(), c.golang, ~U[2026-11-04 05:00:00.000000Z])

    verb_at(
      fs,
      :move,
      lb,
      %{"state" => "in_progress", "stage" => "technical_1"},
      ~U[2026-11-05 05:00:00.000000Z]
    )

    # Tanweer says *I applied* in the portal on one Fiza saved.
    saved = lead_fixture(fs, team: c.backend, profile: c.golang)
    ts = customer_scope_for(c.tanweer)

    {:ok, _sheet} =
      Act.portal_applied(
        ts,
        saved.id,
        %{"from" => %{"state" => "todo", "stage" => nil}},
        ~U[2026-11-11 05:00:00.000000Z]
      )

    # Naveed's work is not Tanweer's.
    naveed = profile_fixture(c.naveed, title: "Rust backend", owners: [c.fiza])
    ln = apply_at(fs, job.(), naveed, ~U[2026-11-10 06:00:00.000000Z])

    Map.merge(c, %{fs: fs, ts: ts, la: la, lb: lb, ln: ln})
  end

  test "this week, last week and the stages, their own profiles only", c do
    {:ok, home} = Dashboards.home(c.ts, @now)

    assert [
             %{
               profile: %{id: id, title: "Golang backend"},
               this_week: 2,
               last_week: 1,
               stages: stages
             }
           ] =
             home.profiles

    assert id == c.golang.id

    assert stages == [
             %{key: "applied", label: "Applied", count: 2},
             %{key: "technical_1", label: "Technical interview 1", count: 1}
           ]
  end

  test "next: their scheduled meetings, approvals waiting on them, tasks given to them", c do
    m = meeting_fixture(c.fs, lead: c.la, starts_at: ~U[2026-11-13 05:00:00.000000Z])

    meeting_fixture(c.fs,
      lead: c.la,
      status: :cancelled,
      starts_at: ~U[2026-11-14 05:00:00.000000Z]
    )

    meeting_fixture(c.fs, lead: c.ln, starts_at: ~U[2026-11-13 06:00:00.000000Z])

    a = approval_fixture(c.fs, lead: c.la, state: :pending, slots: [:customer])
    approval_fixture(c.fs, lead: c.la, state: :pending, slots: [:team_lead])

    t =
      task_fixture(c.fs,
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned,
        due_at: ~U[2026-11-13 20:00:00.000000Z]
      )

    task_fixture(c.fs, team: c.backend, customer: c.tanweer, customer_access: :shared)

    {:ok, home} = Dashboards.home(c.ts, @now)

    assert [%{id: mid, title: "Technical interview", time_zone: "Europe/Berlin"}] =
             home.next.meetings

    assert [%{id: aid}] = home.next.approvals
    # Due 20:00 UTC on the 13th is the 14th in Karachi.
    assert [%{id: tid, due_on: ~D[2026-11-14]}] = home.next.tasks
    assert {mid, aid, tid} == {m.id, a.id, t.id}
  end

  test "replies follow the team: names hidden, then conversations hidden", c do
    reply_at(c.fs, c.la, ~U[2026-11-11 06:00:00.000000Z],
      body_text: "Thanks — could you do a call on Friday?"
    )

    reply_at(c.fs, c.ln, ~U[2026-11-11 07:00:00.000000Z])

    {:ok, home} = Dashboards.home(c.ts, @now)

    assert [
             %{
               lead_id: id,
               title: "Backend Developer",
               from_name: "Mei Chen",
               excerpt: "Thanks — could you do a call on Friday?"
             }
           ] =
             home.replies

    assert id == c.la.id

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    assert {:ok, %{replies: [%{from_name: nil}]}} = Dashboards.home(c.ts, @now)

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    assert {:ok, %{replies: nil}} = Dashboards.home(c.ts, @now)
  end

  test "staff find nothing", c do
    assert {:error, :not_found} = Dashboards.home(c.fs, @now)
  end
end
