defmodule Core.Leads.LedgerTest do
  @moduledoc """
  AQ-11 §7.4 (QP11-5): the ledger writes `stage_kind` — the engine kind of
  the stage reached — on `applied` and `stage_moved`, a custom stage as its
  anchor, and on no other kind; the database refuses it anywhere else.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Data.Leads.Event
  alias Data.Pipelines

  @at ~U[2026-11-12 07:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.put(c, :fs, scope_for(c.fiza))
  end

  defp events(lead_id) do
    from(e in Event, where: e.lead_id == ^lead_id, order_by: [asc: e.recorded_at, asc: e.kind])
    |> Repo.all()
    |> Enum.map(&{&1.kind, &1.stage_kind})
  end

  test "applied and stage_moved carry the kind reached; the rest carry none", c do
    job = job_fixture(c.fs, team: c.backend)
    lead = apply_at(c.fs, job, c.golang, @at)
    lead = verb_at(c.fs, :move, lead, %{"state" => "in_progress", "stage" => "technical_1"}, @at)
    lead = verb_at(c.fs, :hold, lead, %{"hold_reason" => "Waiting"}, @at)
    lead = verb_at(c.fs, :resume, lead, %{"stage" => "offer"}, @at)
    _lead = verb_at(c.fs, :finish, lead, %{"outcome" => "hired"}, @at)

    assert Enum.sort(events(lead.id)) ==
             Enum.sort([
               {:applied, :applied},
               {:stage_moved, :interview},
               {:state_moved, nil},
               {:stage_moved, :offer},
               {:state_moved, nil},
               {:outcome_set, nil}
             ])
  end

  test "a custom stage is written as the engine kind it is anchored to", c do
    stages =
      Pipelines.defaults(:employment)
      |> List.insert_at(5, %{
        key: "pair_session",
        name: "Pair session",
        kind: :custom,
        anchor_kind: :interview
      })

    pipeline_fixture(c.fs, key: :employment, stages: stages)
    lead = apply_at(c.fs, job_fixture(c.fs, team: c.backend), c.golang, @at)

    _lead =
      verb_at(c.fs, :move, lead, %{"state" => "in_progress", "stage" => "pair_session"}, @at)

    assert {:stage_moved, :interview} in events(lead.id)
  end

  test "the database refuses a stage kind on any other kind of row", c do
    lead = apply_at(c.fs, job_fixture(c.fs, team: c.backend), c.golang, @at)

    {:error, changeset} =
      Data.Leads.add_event(%{
        organisation_id: c.org.id,
        lead_id: lead.id,
        kind: :follow_up_logged,
        occurred_at: @at,
        recorded_at: @at,
        actor_kind: :user,
        actor_user_id: c.fiza.id,
        visibility: :customer,
        stage_kind: :interview
      })

    assert %{stage_kind: [_message]} = errors_on(changeset)
  end
end
