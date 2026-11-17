defmodule Data.Filters.TriageTest do
  @moduledoc """
  `Data.Filters.Triage` through `Data.Conversations.triage/3`:
  `profile_owner` against `Data.Dashboards.triage_owners/1` (the rule the
  tile counts with), and the 422.
  """

  use Data.DataCase, async: true

  alias Data.Conversations
  alias Data.Dashboards

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    # Tanweer's Golang backend profile is Fiza's and Qasim's; Naveed's has no owner.
    _naveed = profile_fixture(c.naveed, title: "Golang")
    tanweers = conversation_fixture(fs, team: c.backend, customer: c.tanweer)
    naveeds = conversation_fixture(fs, team: c.backend, customer: c.naveed)
    nobodys = conversation_fixture(fs, team: c.backend)
    Map.merge(c, %{tanweers: tanweers, naveeds: naveeds, nobodys: nobodys})
  end

  defp ids(c, who, where) do
    {:ok, items} = Conversations.triage(c.backend.id, where, %{user_id: who.id})
    items |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp owned(c, who) do
    for(r <- Dashboards.triage_owners([c.backend.id]), r.user_id == who.id, do: r.conversation_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "no $where: every item of the team", c do
    assert ids(c, c.fiza, nil) == Enum.sort([c.tanweers.id, c.naveeds.id, c.nobodys.id])
  end

  test "profile_owner: me or an id, as the tile counts it", c do
    assert ids(c, c.fiza, %{"profile_owner" => %{"$EQUAL" => "me"}}) == owned(c, c.fiza)
    assert owned(c, c.fiza) == [c.tanweers.id]
    assert ids(c, c.fiza, %{"profile_owner" => %{"$EQUAL" => c.qasim.id}}) == owned(c, c.qasim)
    assert ids(c, c.muaz, %{"profile_owner" => "me"}) == []
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"platform" => "email"}, "platform"},
          {%{"profile_owner" => %{"$IN" => ["me"]}}, "profile_owner"},
          {%{"profile_owner" => %{"$EQUAL" => "someone"}}, "profile_owner"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Conversations.triage(c.backend.id, where, %{user_id: c.fiza.id})
    end
  end
end
