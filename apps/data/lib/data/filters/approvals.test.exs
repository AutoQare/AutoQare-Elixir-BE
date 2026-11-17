defmodule Data.Filters.ApprovalsTest do
  @moduledoc """
  `Data.Filters.Approvals`: each field and operator, `due` against a direct
  query at a given *now*, the refusals, and `Data.Approvals.page/3`
  narrowing whose rows they are first.
  """

  use Data.DataCase, async: true

  alias Data.Approvals.Approval
  alias Data.Filters

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    naveed_profile = profile_fixture(c.naveed, title: "Rails", owners: [c.fiza])
    other = lead_fixture(fiza, team: c.backend, profile: naveed_profile, as: :apply)

    a = %{
      late:
        approval_fixture(fiza,
          lead: lead,
          approval_kind: :cv_for_job,
          state: :pending,
          due_at: ~U[2026-11-09 12:00:00Z]
        ),
      soon:
        approval_fixture(fiza,
          lead: lead,
          approval_kind: :reply,
          state: :pending,
          due_at: ~U[2026-11-14 12:00:00Z]
        ),
      far:
        approval_fixture(fiza,
          lead: other,
          approval_kind: :reply,
          state: :pending,
          due_at: ~U[2026-11-30 12:00:00Z]
        ),
      done:
        approval_fixture(fiza,
          lead: other,
          approval_kind: :rate,
          state: :approved,
          due_at: ~U[2026-11-01 12:00:00Z]
        ),
      draft: approval_fixture(fiza, lead: lead, approval_kind: :proposal)
    }

    Map.merge(c, %{a: a, lead: lead, other: other, ctx: %{now: @now}})
  end

  defp ids(c, where) do
    base = from(x in Approval, where: x.organisation_id == ^c.org.id)
    {:ok, query} = Filters.where(base, Filters.Approvals, where, c.ctx)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(c, condition) do
    from(x in Approval, where: x.organisation_id == ^c.org.id)
    |> where(^condition)
    |> Repo.all()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp sorted(list), do: list |> Enum.map(& &1.id) |> Enum.sort()

  test "kind, state, customer_id, lead_id: $EQUAL and $IN", c do
    assert ids(c, %{"kind" => %{"$EQUAL" => "cv_for_job"}}) == [c.a.late.id]

    assert ids(c, %{"kind" => %{"$IN" => ["reply", "rate"]}}) ==
             sorted([c.a.soon, c.a.far, c.a.done])

    assert ids(c, %{"state" => %{"$EQUAL" => "draft"}}) == [c.a.draft.id]

    assert ids(c, %{"state" => %{"$IN" => ["approved", "draft"]}}) ==
             sorted([c.a.done, c.a.draft])

    assert ids(c, %{"customer_id" => %{"$EQUAL" => c.naveed.id}}) == sorted([c.a.far, c.a.done])

    assert ids(c, %{"customer_id" => %{"$IN" => [c.tanweer.id]}}) ==
             sorted([c.a.late, c.a.soon, c.a.draft])

    assert ids(c, %{"lead_id" => %{"$EQUAL" => c.other.id}}) == sorted([c.a.far, c.a.done])

    assert ids(c, %{"lead_id" => %{"$IN" => [c.lead.id]}}) ==
             sorted([c.a.late, c.a.soon, c.a.draft])
  end

  test "due: overdue and week at now, each as a direct query", c do
    overdue = direct(c, dynamic([x], x.state == :pending and x.due_at < ^@now))
    assert ids(c, %{"due" => %{"$EQUAL" => "overdue"}}) == overdue
    assert overdue == [c.a.late.id]

    week_end = ~U[2026-11-17 09:00:00.000000Z]

    week =
      direct(
        c,
        dynamic([x], x.state == :pending and not is_nil(x.due_at) and x.due_at <= ^week_end)
      )

    assert ids(c, %{"due" => %{"$EQUAL" => "week"}}) == week
    assert week == sorted([c.a.late, c.a.soon])
  end

  test "what the list doesn't take is refused, naming the field", c do
    base = from(x in Approval, where: x.organisation_id == ^c.org.id)

    for {where, field} <- [
          {%{"title" => "x"}, "title"},
          {%{"approval_kind" => "reply"}, "approval_kind"},
          {%{"kind" => %{"$EQUAL" => "nonsense"}}, "kind"},
          {%{"state" => %{"$GT" => "draft"}}, "state"},
          {%{"due" => %{"$EQUAL" => "month"}}, "due"},
          {%{"due" => %{"$IN" => ["week"]}}, "due"},
          {%{"lead_id" => %{"$EQUAL" => "not-an-id"}}, "lead_id"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Approvals, where, c.ctx)
    end
  end

  test "page/3: whose first (the team's, or the customer's own with a slot), then $where", c do
    assert {:ok, rows} =
             Data.Approvals.page(
               [team_id: c.backend.id],
               %{"kind" => %{"$EQUAL" => "reply"}},
               c.ctx
             )

    assert sorted(rows) == sorted([c.a.soon, c.a.far])

    assert {:ok, rows} =
             Data.Approvals.page(
               [customer_id: c.tanweer.id, customer_slot: true],
               %{"due" => %{"$EQUAL" => "week"}},
               c.ctx
             )

    assert sorted(rows) == sorted([c.a.late, c.a.soon])

    assert {:error, {:invalid_filter, %{"colour" => _}}} =
             Data.Approvals.page([team_id: c.backend.id], %{"colour" => "red"}, c.ctx)
  end
end
