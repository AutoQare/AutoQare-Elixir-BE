defmodule Data.Filters.MeetingsTest do
  @moduledoc """
  `Data.Filters.Meetings`: `starts_at` by instant and by day, `status`,
  `upcoming` against a direct query at a given *now*, the refusals, and
  `Data.Meetings.list/3`'s upcoming default.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Meetings.Meeting

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)

    m = %{
      past: meeting_fixture(fiza, lead: lead, starts_at: ~U[2026-11-09 10:00:00Z]),
      now: meeting_fixture(fiza, lead: lead, starts_at: ~U[2026-11-10 08:30:00Z]),
      soon: meeting_fixture(fiza, lead: lead, starts_at: ~U[2026-11-12 10:00:00Z]),
      off:
        meeting_fixture(fiza,
          lead: lead,
          starts_at: ~U[2026-11-13 10:00:00Z],
          status: :cancelled
        )
    }

    Map.merge(c, %{m: m, ctx: %{now: @now}})
  end

  defp ids(c, where) do
    base = from(x in Meeting, where: x.organisation_id == ^c.org.id)
    {:ok, query} = Filters.where(base, Filters.Meetings, where, c.ctx)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp sorted(list), do: list |> Enum.map(& &1.id) |> Enum.sort()

  test "starts_at: an instant's window, a UTC day's", c do
    assert ids(c, %{
             "starts_at" => %{"$GTE" => "2026-11-10T00:00:00Z", "$LT" => "2026-11-13T00:00:00Z"}
           }) == sorted([c.m.now, c.m.soon])

    assert ids(c, %{"starts_at" => %{"$GT" => "2026-11-12T10:00:00Z"}}) == [c.m.off.id]
    assert ids(c, %{"starts_at" => %{"$LTE" => "2026-11-09T10:00:00Z"}}) == [c.m.past.id]

    assert ids(c, %{
             "starts_at" => %{
               "$CAST_TO_DATE_GTE" => "2026-11-12",
               "$CAST_TO_DATE_LTE" => "2026-11-12"
             }
           }) == [c.m.soon.id]
  end

  test "status, and upcoming as a direct query", c do
    assert ids(c, %{"status" => %{"$EQUAL" => "cancelled"}}) == [c.m.off.id]

    assert ids(c, %{"status" => %{"$IN" => ["scheduled"]}}) ==
             sorted([c.m.past, c.m.now, c.m.soon])

    upcoming =
      from(x in Meeting,
        where:
          x.organisation_id == ^c.org.id and x.status in [:scheduled, :proposed] and
            x.ends_at > ^@now,
        select: x.id
      )
      |> Repo.all()
      |> Enum.sort()

    assert ids(c, %{"upcoming" => %{"$EQUAL" => "true"}}) == upcoming
    assert upcoming == sorted([c.m.now, c.m.soon])
    assert length(ids(c, %{"upcoming" => %{"$EQUAL" => false}})) == 4
  end

  test "list/3 is the upcoming ones unless upcoming, starts_at or status is named", c do
    assert {:ok, rows} = Data.Meetings.list([team_id: c.backend.id], nil, c.ctx)
    assert Enum.map(rows, & &1.id) == [c.m.now.id, c.m.soon.id]

    window = %{"starts_at" => %{"$LT" => "2026-11-10T00:00:00Z"}}
    assert {:ok, [past]} = Data.Meetings.list([team_id: c.backend.id], window, c.ctx)
    assert past.id == c.m.past.id

    # A status names the meetings asked for, past or cancelled ones too.
    cancelled = %{"status" => %{"$EQUAL" => "cancelled"}}
    assert {:ok, [off]} = Data.Meetings.list([team_id: c.backend.id], cancelled, c.ctx)
    assert off.id == c.m.off.id

    # An empty status is no filter: the upcoming default still holds.
    blank = %{"status" => ""}
    assert {:ok, rows} = Data.Meetings.list([team_id: c.backend.id], blank, c.ctx)
    assert Enum.map(rows, & &1.id) == [c.m.now.id, c.m.soon.id]

    everything = %{"upcoming" => %{"$EQUAL" => false}}
    assert {:ok, rows} = Data.Meetings.list([customer_id: c.tanweer.id], everything, c.ctx)
    assert length(rows) == 4
  end

  test "what the list doesn't take is refused, naming the field", c do
    base = from(x in Meeting, where: x.organisation_id == ^c.org.id)

    for {where, field} <- [
          {%{"from" => "2026-11-10T00:00:00Z"}, "from"},
          {%{"starts_at" => %{"$EQUAL" => "2026-11-10T00:00:00Z"}}, "starts_at"},
          {%{"starts_at" => %{"$GTE" => "tomorrow"}}, "starts_at"},
          {%{"starts_at" => %{"$CAST_TO_DATE_GTE" => "12/11"}}, "starts_at"},
          {%{"upcoming" => %{"$EQUAL" => "soon"}}, "upcoming"},
          {%{"status" => %{"$IN" => ["lost"]}}, "status"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Meetings, where, c.ctx)
    end
  end
end
