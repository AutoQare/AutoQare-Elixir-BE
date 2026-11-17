defmodule Data.Filters.AuditTest do
  @moduledoc """
  `Data.Filters.Audit`: each field and operator, the days in the
  organisation's zone against a direct query, and the 422.
  """

  use Data.DataCase, async: true

  alias Data.Audit.AuditEvent
  alias Data.Filters

  setup do
    # Asia/Karachi, UTC+5: 20:00 UTC on the 13th is 01:00 on the 14th there.
    org = organisation_fixture(%{timezone: "Asia/Karachi"})
    team = team_fixture(org)
    lead = member_fixture(team, :lead)
    scope = scope_for(lead, organisation: org)

    late = event(org, lead.id, "teams", team.id, "updated", ~U[2026-11-13 20:00:00.000000Z])
    early = event(org, lead.id, "teams", team.id, "created", ~U[2026-11-13 18:00:00.000000Z])

    system =
      event(
        org,
        nil,
        "customers",
        Ecto.UUID.generate(),
        "updated",
        ~U[2026-11-15 06:00:00.000000Z]
      )

    %{org: org, scope: scope, lead: lead, team: team, late: late, early: early, system: system}
  end

  defp event(org, actor, kind, subject_id, action, at) do
    {:ok, event} =
      Data.Audit.insert(%{
        organisation_id: org.id,
        actor_user_id: actor,
        via: :web,
        subject_kind: kind,
        subject_id: subject_id,
        action: action,
        occurred_at: at
      })

    event
  end

  defp ids(c, where) do
    base = from(e in AuditEvent, where: e.organisation_id == ^c.org.id)
    context = Filters.context(c.scope, [])
    {:ok, query} = Filters.where(base, Filters.Audit, where, context)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  defp sorted(list), do: Enum.sort(list)

  test "subject_kind, subject_id, action: $EQUAL and $IN", c do
    assert ids(c, %{"subject_kind" => %{"$EQUAL" => "teams"}}) == sorted([c.late.id, c.early.id])
    assert ids(c, %{"subject_kind" => %{"$IN" => ["teams", "customers"]}}) |> length() == 3
    assert ids(c, %{"subject_id" => %{"$EQUAL" => c.team.id}}) == sorted([c.late.id, c.early.id])
    assert ids(c, %{"subject_id" => %{"$IN" => [c.system.subject_id]}}) == [c.system.id]
    assert ids(c, %{"action" => "created"}) == [c.early.id]
    assert ids(c, %{"action" => %{"$IN" => ["created", "updated"]}}) |> length() == 3
  end

  test "actor: $EQUAL, $IN, $NULL (the system's rows), $NOT_NULL", c do
    assert ids(c, %{"actor" => %{"$EQUAL" => c.lead.id}}) == sorted([c.late.id, c.early.id])
    assert ids(c, %{"actor" => %{"$IN" => [c.lead.id]}}) == sorted([c.late.id, c.early.id])
    assert ids(c, %{"actor" => %{"$NULL" => true}}) == [c.system.id]
    assert ids(c, %{"actor" => %{"$NOT_NULL" => true}}) == sorted([c.late.id, c.early.id])
  end

  test "occurred_at: local days in the organisation's zone, both ends kept, as a direct query",
       c do
    # The 14th in Karachi runs from 19:00 UTC on the 13th to 19:00 UTC on the 14th.
    from = ~U[2026-11-13 19:00:00.000000Z]
    to = ~U[2026-11-14 19:00:00.000000Z]

    expected =
      direct(
        from(e in AuditEvent,
          where: e.organisation_id == ^c.org.id and e.occurred_at >= ^from and e.occurred_at < ^to
        )
      )

    assert expected == [c.late.id]
    assert ids(c, %{"occurred_at" => %{"$CAST_TO_DATE_EQUAL" => "2026-11-14"}}) == expected

    assert ids(c, %{
             "occurred_at" => %{
               "$CAST_TO_DATE_GTE" => "2026-11-14",
               "$CAST_TO_DATE_LTE" => "2026-11-14"
             }
           }) == expected

    assert ids(c, %{"occurred_at" => %{"$CAST_TO_DATE_LTE" => "2026-11-13"}}) == [c.early.id]

    assert ids(c, %{"occurred_at" => %{"$CAST_TO_DATE_GTE" => "2026-11-14"}}) ==
             sorted([c.late.id, c.system.id])
  end

  test "anything else is refused, naming the field", c do
    base = from(e in AuditEvent, where: e.organisation_id == ^c.org.id)

    for {where, field} <- [
          {%{"via" => "web"}, "via"},
          {%{"from" => "2026-11-14"}, "from"},
          {%{"occurred_at" => %{"$GTE" => "2026-11-14"}}, "occurred_at"},
          {%{"occurred_at" => %{"$CAST_TO_DATE_GTE" => "yesterday"}}, "occurred_at"},
          {%{"subject_id" => "not-an-id"}, "subject_id"},
          {%{"actor" => %{"$ILIKE" => "x"}}, "actor"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Audit, where, Filters.context(c.scope, []))
    end
  end
end
