defmodule Data.Filters.HistoryTest do
  @moduledoc "`Data.Filters.History` through `Data.Leads.history/3`: `kind` by each operator, and the 422."

  use Data.DataCase, async: true

  alias Data.Leads

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)

    for {kind, n} <- [applied: 1, note_added: 2, stage_moved: 3] do
      at = DateTime.add(~U[2026-11-14 09:00:00.000000Z], n, :second)

      {:ok, _event} =
        Leads.add_event(%{
          organisation_id: c.org.id,
          lead_id: lead.id,
          kind: kind,
          occurred_at: at,
          recorded_at: at,
          actor_kind: :user,
          actor_user_id: c.fiza.id,
          visibility: :staff
        })
    end

    Map.put(c, :lead, lead)
  end

  defp kinds(c, where) do
    {:ok, events} = Leads.history(c.lead.id, where, limit: 50)
    Enum.map(events, & &1.kind)
  end

  test "kind: $EQUAL, $IN, $NOT_IN; newest first", c do
    assert kinds(c, nil) == [:stage_moved, :note_added, :applied]
    assert kinds(c, %{"kind" => "applied"}) == [:applied]
    assert kinds(c, %{"kind" => %{"$EQUAL" => "note_added"}}) == [:note_added]

    assert kinds(c, %{"kind" => %{"$IN" => ["applied", "stage_moved"]}}) == [
             :stage_moved,
             :applied
           ]

    assert kinds(c, %{"kind" => %{"$NOT_IN" => ["applied"]}}) == [:stage_moved, :note_added]
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"actor" => "me"}, "actor"},
          {%{"kind" => %{"$GT" => "applied"}}, "kind"},
          {%{"kind" => %{"$IN" => ["lunch"]}}, "kind"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Leads.history(c.lead.id, where, limit: 50)
    end
  end
end
