defmodule Data.Filters.Audit do
  @moduledoc """
  The audit log's `$where` (AQ-11B §3 #9): `GET /team/v1/org/audit` and a
  customer's `GET /customers/:id/activity`. Whose rows they are — the
  organisation's, the teams a lead leads, the rows naming the customer
  (the JSON matches on `before` / `after`) — is the base query's
  (`Data.Audit.list/5`); this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `subject_kind` | `$EQUAL` `$IN` | the row's subject table (`teams`, `customers`, `leads`, …) |
  | `subject_id` | `$EQUAL` `$IN` | the subject's id |
  | `actor` | `$EQUAL` `$IN` `$NULL` `$NOT_NULL` | who acted (`actor_user_id`); `$NULL` the system's rows |
  | `action` | `$EQUAL` `$IN` | what was done (`created`, `updated`, …) |
  | `occurred_at` | `$CAST_TO_DATE_GTE` `$CAST_TO_DATE_LTE` `$CAST_TO_DATE_EQUAL` | local days (`YYYY-MM-DD`), **in the organisation's zone**, both ends kept: `GTE` from the day's first instant, `LTE` to the end of the day, `EQUAL` that one day (`Utils.Days`' windows, the dashboards' copy) |

  FatEcto's own `$CAST_TO_DATE_*` compares the UTC day; the audit's are
  overrides with the same names so a day is the organisation's, as every
  other date in the console is.
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      subject_kind: ["$EQUAL", "$IN"],
      subject_id: ["$EQUAL", "$IN"],
      actor: {:actor_user_id, ["$EQUAL", "$IN", "$NULL", "$NOT_NULL"]},
      action: ["$EQUAL", "$IN"]
    ],
    overrideable: ["occurred_at"],
    ignoreable: [
      subject_kind: ["", nil, []],
      subject_id: ["", nil, []],
      actor: ["", []],
      action: ["", nil, []],
      occurred_at: ["", nil]
    ]

  use Data.Filters,
    operators: [occurred_at: ["$CAST_TO_DATE_GTE", "$CAST_TO_DATE_LTE", "$CAST_TO_DATE_EQUAL"]]

  import Ecto.Query

  alias Data.Filters

  @impl Data.Filters
  def prepare("occurred_at", _operator, value, context) do
    with {:ok, day} <- Filters.date(value),
         do: {:ok, Filters.day_range(day, day, Map.get(context, :zone, "Etc/UTC"))}
  end

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("occurred_at", "$CAST_TO_DATE_GTE", {from, _to}),
    do: dynamic([e], e.occurred_at >= ^from)

  def override_buildable("occurred_at", "$CAST_TO_DATE_LTE", {_from, to}),
    do: dynamic([e], e.occurred_at < ^to)

  def override_buildable("occurred_at", "$CAST_TO_DATE_EQUAL", {from, to}),
    do: dynamic([e], e.occurred_at >= ^from and e.occurred_at < ^to)

  def override_buildable(_field, _operator, _value), do: nil
end
