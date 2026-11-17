defmodule Core.Approvals.NoticesTest do
  @moduledoc """
  AQ-10B §5.4 and §11.4's email rules through the approval verbs: asked
  is emailed for the first version and for a revision that needs a new
  decision, not otherwise; decided emails the requester alone; withdrawn
  tells the open slots' people; due soon never emails.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Approvals
  alias Core.Approvals.Act
  alias Core.Approvals.Notices
  alias Data.Notifications.{Deliveries, Notification}

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer")
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)
    Map.merge(c, %{fiza_s: fiza, tanweer_s: customer_scope_for(c.tanweer), lead: lead})
  end

  defp submitted(c, slots \\ [%{slot: "customer"}, %{slot: "team_lead"}]) do
    {:ok, a} =
      Approvals.draft(
        c.fiza_s,
        %{
          team_id: c.backend.id,
          lead_id: c.lead.id,
          approval_kind: "other",
          title: "Reply to Mei",
          body_md: "Hi",
          slots: slots
        },
        @now
      )

    {:ok, a} = Act.submit(c.fiza_s, a.id, @now)
    a
  end

  defp rows(user_id, kind) do
    from(n in Notification,
      where: n.user_id == ^user_id and n.notification_kind_key == ^kind,
      order_by: n.inserted_at
    )
    |> Repo.all()
  end

  defp email?(n), do: Enum.any?(Deliveries.for_notification(n.id), &(&1.channel == :email))

  test "the first version and a revision after changes are emailed; a revision before any decision isn't",
       c do
    a = submitted(c)
    assert [first] = rows(c.tanweer.user_id, "approvals.requested")
    assert email?(first)

    # Fiza revises while nobody has decided: in-app and push only.
    {:ok, a} = Act.revise(c.fiza_s, a.id, %{body_md: "Hi again"}, @now)
    assert [_first, quiet] = rows(c.tanweer.user_id, "approvals.requested")
    refute email?(quiet)

    # Changes asked, then a revision: a new decision is needed, so it emails.
    {:ok, a} =
      Act.decide(
        c.tanweer_s,
        a.id,
        %{decision: "changes_requested", version: 2, note: "Shorter"},
        @now
      )

    {:ok, _a} = Act.revise(c.fiza_s, a.id, %{body_md: "Hi"}, @now)
    assert [_, _, again] = rows(c.tanweer.user_id, "approvals.requested")
    assert email?(again)
  end

  test "decided: the requester emailed, the other reviewers in-app and push only", c do
    a = submitted(c, [%{slot: "customer"}, %{slot: "team_lead"}])

    {:ok, _a} =
      Act.decide(
        c.tanweer_s,
        a.id,
        %{decision: "changes_requested", version: 1, note: "No"},
        @now
      )

    assert [mine] = rows(c.fiza.id, "approvals.decided")
    assert email?(mine)

    assert [theirs] = rows(c.hira.id, "approvals.decided")
    refute email?(theirs)
  end

  test "withdrawn tells the open slots' people, not the requester", c do
    a = submitted(c)
    {:ok, _} = Act.withdraw(c.fiza_s, a.id, @now)

    assert [%{title: "Fiza withdrew Reply to Mei"}] = rows(c.hira.id, "approvals.withdrawn")
    assert [_] = rows(c.tanweer.user_id, "approvals.withdrawn")
    assert rows(c.fiza.id, "approvals.withdrawn") == []
  end

  test "due soon is in-app and push alone (QP10b-20)", c do
    a = submitted(c)

    a =
      a.id
      |> Data.Approvals.get_for_system()
      |> Map.put(:due_at, DateTime.add(@now, 86_400, :second))

    _events = Notices.due(Data.Scope.system(c.org), a, :due_soon)

    assert [n] = rows(c.tanweer.user_id, "approvals.due_soon")
    refute email?(n)
  end
end
