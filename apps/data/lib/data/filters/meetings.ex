defmodule Data.Filters.Meetings do
  @moduledoc """
  Meetings' `$where` in both apps (`GET /team/v1/meetings`, `GET
  /client/v1/meetings`; AQ-11B §3 #6). The meetings of the team's leads
  (the console) or of the customer's (the portal) are the base query's,
  and the per-row read check stays the context's; this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `starts_at` | `$GTE` `$GT` `$LT` `$LTE` (an instant, ISO 8601), `$CAST_TO_DATE_GTE` `$CAST_TO_DATE_LTE` (a UTC day) | when it starts: the week view sends `{$GTE: from, $LT: to}` |
  | `status` | `$EQUAL` `$IN` | its status (`meeting_statuses`) |
  | `upcoming` | `$EQUAL` | `true`: scheduled or proposed and not ended at *now* (the old default, now a filter the client sends); `false`: no filter |

  **With none of `upcoming`, `starts_at` and `status`, the list is the
  upcoming ones** (`Data.Meetings.list/3` defaults `upcoming` to `true`),
  as it was before `$where`; `upcoming {$EQUAL: false}`, a time or a
  status lifts it (`status {$EQUAL: "cancelled"}` finds the cancelled).
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      starts_at: ["$GTE", "$GT", "$LT", "$LTE", "$CAST_TO_DATE_GTE", "$CAST_TO_DATE_LTE"],
      status: ["$EQUAL", "$IN"]
    ],
    overrideable: ["upcoming"],
    ignoreable: [upcoming: ["", nil], status: ["", nil, []], starts_at: ["", nil]]

  use Data.Filters, operators: [upcoming: ["$EQUAL"]]

  import Ecto.Query

  @impl Data.Filters
  def prepare("upcoming", "$EQUAL", value, %{now: %DateTime{} = now}) do
    case Data.Filters.boolean(value) do
      {:ok, true} -> {:ok, now}
      {:ok, false} -> {:ok, nil}
      :error -> :error
    end
  end

  def prepare(_field, _op, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("upcoming", "$EQUAL", %DateTime{} = now),
    do: dynamic([m], m.status in [:scheduled, :proposed] and m.ends_at > ^now)

  def override_buildable(_field, _operator, _value), do: nil
end
