defmodule Core.Workers.ObservationSweepTest do
  @moduledoc """
  AQ-10 §9, §11.4: the daily sweep deletes observations past the
  organisation's 180 days and keeps the hour counts; it holds no rule and
  a second run deletes nothing.
  """

  use Core.CoreCase, async: true

  alias Core.Workers.ObservationSweep
  alias Data.Behaviour.{Observation, SubjectHour}

  test "old observations go, the counts stay; run twice, the second deletes nothing" do
    c = board_cast_fixture()
    corvid = company_fixture(c.org, name: "Corvid Security")
    _job = job_fixture(scope_for(c.fiza), team: c.backend, company: corvid)
    now = Core.Clock.now()

    for days <- [200, 1] do
      at = DateTime.add(now, -days * 86_400, :second)

      {:ok, _} =
        Core.Behaviour.observe(scope_for(c.fiza), %{
          company_id: corvid.id,
          kind: :seen_online,
          source: :manual,
          observed_at: at,
          active_at: at
        })
    end

    assert :ok = ObservationSweep.perform(%Oban.Job{})
    assert [%{observed_at: kept}] = Repo.all(Observation)
    assert DateTime.diff(now, kept, :day) == 1

    assert :ok = ObservationSweep.perform(%Oban.Job{})
    assert length(Repo.all(Observation)) == 1
    assert Repo.all(SubjectHour) |> Enum.map(& &1.count) |> Enum.sum() == 2
  end
end
