defmodule Data.Filters.CheckTest do
  @moduledoc """
  The checks before FatEcto builds: a joined column's value cast in the
  schema its binding names, enums, ids, lists, ranges and dates.
  """

  use Data.DataCase, async: true

  alias Data.Filters.Check
  alias Data.Meetings.Meeting

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    %{query: Data.Leads.team_query(team.id)}
  end

  test "a joined table's column casts in its own schema: the job's source", %{query: query} do
    assert {:ok, %{"source" => %{"$IN" => [:linkedin]}}} =
             Check.run(%{"source" => %{"$IN" => ["linkedin"]}}, Data.Filters.Leads, query, %{})

    assert {:error, {:invalid_filter, %{"source" => _}}} =
             Check.run(%{"source" => %{"$IN" => ["myspace"]}}, Data.Filters.Leads, query, %{})
  end

  test "an enum on the root, a list sent as an indexed map, ids", %{query: query} do
    assert {:ok, %{"state" => %{"$IN" => [:todo, :done]}}} =
             Check.run(
               %{"state" => %{"$IN" => %{"1" => "done", "0" => "todo"}}},
               Data.Filters.Leads,
               query,
               %{}
             )

    assert {:error, {:invalid_filter, %{"profile" => _}}} =
             Check.run(%{"profile" => "not-an-id"}, Data.Filters.Leads, query, %{})
  end

  test "instants and dates: each end cast, a bad one refused" do
    query = Ecto.Queryable.to_query(Meeting)

    assert {:ok,
            %{"starts_at" => %{"$GTE" => %DateTime{}, "$CAST_TO_DATE_LTE" => ~D[2026-11-20]}}} =
             Check.run(
               %{
                 "starts_at" => %{
                   "$GTE" => "2026-11-14T00:00:00Z",
                   "$CAST_TO_DATE_LTE" => "2026-11-20"
                 }
               },
               Data.Filters.Meetings,
               query,
               %{}
             )

    for bad <- [%{"$GTE" => "yesterday"}, %{"$CAST_TO_DATE_LTE" => "20/11"}] do
      assert {:error, {:invalid_filter, %{"starts_at" => _}}} =
               Check.run(%{"starts_at" => bad}, Data.Filters.Meetings, query, %{})
    end
  end

  test "listed/1 reads one value, a list, or an indexed map" do
    assert Check.listed("a") == ["a"]
    assert Check.listed(["a", "b"]) == ["a", "b"]
    assert Check.listed(%{"1" => "b", "0" => "a"}) == ["a", "b"]
    assert Check.listed(nil) == []
  end
end
