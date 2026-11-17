defmodule Data.DashboardsTest do
  @moduledoc """
  The counter's storage (AQ-11 §4): one query for a set of windows, a
  response read as "the lead's latest response at or after the
  application", interviews each lead once, and the funnel with purged leads
  from their fingerprints. The ledger rows are written as the ledger writes
  them; the rules' kinds are handed in, as `Core.Dashboards.Rules` hands them.
  """

  use Data.DataCase, async: true

  alias Data.Dashboards
  alias Data.Leads

  @rules %{
    response_kinds: [
      :screening,
      :assessment,
      :interview,
      :ai_interview,
      :final,
      :offer,
      :negotiation,
      :contract
    ],
    interview_kinds: [:assessment, :interview, :ai_interview, :final],
    offer_kinds: [:offer, :negotiation, :contract],
    answer_outcomes: [:rejected, :position_closed],
    interview_meetings: [:technical, :assessment_review, :ai_interview, :final],
    meeting_statuses: [:scheduled, :done, :no_show]
  }

  @mon ~U[2026-11-09 05:00:00.000000Z]
  @wed ~U[2026-11-11 05:00:00.000000Z]
  @week {~U[2026-11-08 19:00:00.000000Z], ~U[2026-11-15 19:00:00.000000Z]}
  @monday {~U[2026-11-08 19:00:00.000000Z], ~U[2026-11-09 19:00:00.000000Z]}

  setup do
    c = board_cast_fixture()
    Map.put(c, :fs, scope_for(c.fiza))
  end

  defp event(c, lead, kind, at, attrs) do
    {:ok, e} =
      %{
        organisation_id: c.org.id,
        lead_id: lead.id,
        kind: kind,
        occurred_at: at,
        recorded_at: at,
        actor_kind: :user,
        actor_user_id: c.fiza.id,
        visibility: :customer
      }
      |> Map.merge(Map.new(attrs))
      |> Leads.add_event()

    e
  end

  test "applications and responses per window, in one query", c do
    a = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
    b = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
    event(c, a, :applied, @mon, stage_kind: :applied)
    event(c, b, :applied, @wed, stage_kind: :applied)
    # A's answer comes Tuesday; B's move to screening came before it applied again.
    event(c, a, :stage_moved, DateTime.add(@mon, 86_400, :second), stage_kind: :screening)
    event(c, b, :stage_moved, DateTime.add(@wed, -3600, :second), stage_kind: :screening)

    subject = %{organisation_id: c.org.id, actor_user_id: c.fiza.id}

    assert Dashboards.applications(subject, %{week: @week, monday: @monday}, @rules) == %{
             week: %{count: 2, responses: 1},
             monday: %{count: 1, responses: 1}
           }

    assert [%{group: id, week: %{count: 2}}] =
             Dashboards.applications(subject, %{week: @week}, @rules, :profile)

    assert id == c.golang.id
  end

  test "interviews: each lead once, a meeting or a stage reached", c do
    a = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
    event(c, a, :stage_moved, @mon, stage_kind: :interview)
    meeting_fixture(c.fs, lead: a, meeting_kind: :technical, starts_at: @wed)
    meeting_fixture(c.fs, lead: a, meeting_kind: :screening, starts_at: @wed)

    subject = %{organisation_id: c.org.id, team_ids: [c.backend.id]}

    assert Dashboards.interviews(subject, %{week: @week, monday: @monday}, @rules) == %{
             week: 1,
             monday: 1
           }
  end

  test "the funnel adds the purged leads applied in the cohort's days", c do
    a = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
    event(c, a, :applied, @mon, stage_kind: :applied)
    event(c, a, :outcome_set, @wed, outcome: :rejected)
    job = job_fixture(c.fs, team: c.backend)

    fingerprint_fixture(c.fs, job, c.golang,
      applied_on: ~D[2026-11-10],
      stage_kinds: [:applied, :offer]
    )

    fingerprint_fixture(c.fs, job, c.golang, applied_on: ~D[2026-10-10], stage_kinds: [:applied])

    subject = %{organisation_id: c.org.id, team_ids: [c.backend.id]}

    assert Dashboards.funnel(subject, @week, {~D[2026-11-09], ~D[2026-11-15]}, @rules) ==
             %{applied: 2, responded: 2, interview: 0, offer: 1, hired: 0}
  end
end
