defmodule Core.Jobs.LeadHooksTest do
  @moduledoc """
  The hooks P3 left for leads (AQ-04A §8.1, QP3-1): the sheet's *Leads on
  this job* with `hidden_leads`, the pool's `has_leads` and
  `not_applied_with` filters, and a merge that moves leads and refuses a
  profile with a lead on both jobs (QP4a-17).
  """

  use Core.CoreCase, async: true

  alias Core.Jobs
  alias Core.Jobs.{Act, Pool}

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer")
    plain = job_fixture(fiza, team: c.backend, title: "No leads")
    Map.merge(c, %{job: job, plain: plain})
  end

  defp titles(scope, team, where) do
    {:ok, %{items: items}} = Pool.list(scope, %{"team_id" => team.id, "$where" => where}, @now)
    items |> Enum.map(& &1.title) |> Enum.sort()
  end

  test "Leads on this job: the rows the caller sees, newest activity first, and how many they don't",
       c do
    mine = lead_fixture(scope_for(c.fiza), job: c.job, profile: c.golang)
    other = lead_fixture(scope_for(c.qasim), job: c.job, profile: profile_fixture(c.naveed))

    {:ok, sheet} = Jobs.get(scope_for(c.hira), c.job.id, @now)
    assert Enum.sort(Enum.map(sheet.leads, & &1.id)) == Enum.sort([mine.id, other.id])
    assert sheet.hidden_leads == 0
    assert hd(sheet.leads).customer.display_name in ["Tanweer", "Naveed"]

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    {:ok, sheet} = Jobs.get(scope_for(c.fiza), c.job.id, @now)
    assert Enum.map(sheet.leads, & &1.id) == [mine.id] and sheet.hidden_leads == 1
  end

  test "has_leads and not_applied_with, against a hand count", c do
    fiza = scope_for(c.fiza)
    _saved = lead_fixture(fiza, job: c.job, profile: c.golang)
    applied_job = job_fixture(fiza, team: c.backend, title: "Applied one")
    _applied = lead_fixture(fiza, job: applied_job, profile: c.golang, state: :in_progress)

    assert titles(fiza, c.backend, %{"has_leads" => %{"$EQUAL" => "true"}}) == [
             "Applied one",
             "Backend Developer"
           ]

    assert titles(fiza, c.backend, %{"has_leads" => %{"$EQUAL" => false}}) == ["No leads"]

    # To do is not an application: only the applied posting is left out.
    assert titles(fiza, c.backend, %{"not_applied_with" => %{"$EQUAL" => c.golang.id}}) == [
             "Backend Developer",
             "No leads"
           ]

    assert {:error, {:invalid_filter, %{"has_leads" => _}}} =
             Pool.list(
               fiza,
               %{"team_id" => c.backend.id, "$where" => %{"has_leads" => "maybe"}},
               @now
             )

    assert Pool.list(
             fiza,
             %{
               "team_id" => c.backend.id,
               "$where" => %{"not_applied_with" => Ecto.UUID.generate()}
             },
             @now
           ) ==
             {:error, :not_found}

    # Applied in another team still counts: the posting, not the row.
    {:ok, _} = Data.Customers.assign_team(c.tanweer, c.frontend.id, ~D[2026-11-10])

    same =
      job_fixture(scope_for(c.hira),
        team: c.frontend,
        url: c.plain.source_url,
        title: "Same posting"
      )

    _there =
      lead_fixture(scope_for(c.hira),
        job: same,
        profile: Data.Profiles.get(c.golang.id),
        state: :in_progress
      )

    assert titles(fiza, c.backend, %{"not_applied_with" => c.golang.id}) == ["Backend Developer"]

    # The keys are the checked profile's: one only inside $OR was never checked.
    assert {:error, {:invalid_filter, %{"not_applied_with" => _}}} =
             Pool.list(
               fiza,
               %{
                 "team_id" => c.backend.id,
                 "$where" => %{"$OR" => [%{"not_applied_with" => c.golang.id}]}
               },
               @now
             )
  end

  test "a merge moves the leads; a profile with a lead on both jobs refuses it in words", c do
    hira = scope_for(c.hira)
    lead = lead_fixture(scope_for(c.fiza), job: c.plain, profile: c.golang, state: :in_progress)

    {:ok, survivor} = Act.merge(hira, c.plain.id, %{"into_job_id" => c.job.id}, @now)
    assert Enum.map(survivor.leads, & &1.id) == [lead.id]
    assert Data.Leads.get(c.org.id, lead.id).job_id == c.job.id

    third = job_fixture(scope_for(c.fiza), team: c.backend, title: "Third")
    _both = lead_fixture(scope_for(c.fiza), job: third, profile: c.golang)

    assert Act.merge(hira, third.id, %{"into_job_id" => c.job.id}, @now) ==
             {:error,
              {:invalid,
               %{
                 "into_job_id" => [
                   "*Golang backend* has a lead on both jobs. Finish or archive one, then merge."
                 ]
               }}}
  end
end
