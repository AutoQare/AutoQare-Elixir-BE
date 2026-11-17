defmodule ApiTeam.MeetingControllerTest do
  @moduledoc """
  `GET /meetings` over HTTP with `$where` (AQ-11B §11.4): the upcoming
  default, `upcoming` as a filter, the week view on `starts_at`, `status`,
  and 422 `invalid_filter` for what the list doesn't take.
  """

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    soon = meeting_fixture(fiza, lead: lead, title: "Soon")

    past =
      meeting_fixture(fiza,
        lead: lead,
        title: "Past",
        starts_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      )

    cancelled =
      meeting_fixture(fiza,
        lead: lead,
        title: "Cancelled",
        status: :cancelled,
        starts_at: DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      )

    Map.merge(c, %{soon: soon, past: past, cancelled: cancelled})
  end

  defp ids(c, query) do
    body(call(c.fiza, :get, "/v1/meetings?team_id=#{c.backend.id}" <> query))["items"]
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  test "upcoming by default and as a filter; false lifts it; status; the week view", c do
    assert ids(c, "") == [c.soon.id]
    assert ids(c, "&$where[upcoming][$EQUAL]=true") == [c.soon.id]

    assert ids(c, "&$where[upcoming][$EQUAL]=false") ==
             Enum.sort([c.soon.id, c.past.id, c.cancelled.id])

    assert ids(c, "&$where[upcoming][$EQUAL]=false&$where[status][$IN][]=cancelled") ==
             [c.cancelled.id]

    from = c.past.starts_at |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    to = c.past.ends_at |> DateTime.to_iso8601()
    assert ids(c, "&$where[starts_at][$GTE]=#{from}&$where[starts_at][$LT]=#{to}") == [c.past.id]
  end

  test "a field, operator or value the list doesn't take is 422 invalid_filter", c do
    for bad <- [
          "&$where[from]=2026-11-01T00:00:00Z",
          "&$where[starts_at][$EQUAL]=2026-11-01T00:00:00Z",
          "&$where[starts_at][$GTE]=soon",
          "&$where[upcoming][$EQUAL]=maybe"
        ] do
      conn = call(c.fiza, :get, "/v1/meetings?team_id=#{c.backend.id}" <> bad)
      assert conn.status == 422, bad
      assert body(conn)["error"]["code"] == "invalid_filter"
    end
  end
end
