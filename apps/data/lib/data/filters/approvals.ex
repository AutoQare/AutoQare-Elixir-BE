defmodule Data.Filters.Approvals do
  @moduledoc """
  Approvals' `$where` in both apps (`GET /team/v1/approvals`, `GET
  /client/v1/approvals`; AQ-11B §3 #5). The team's approvals (the
  console) or the customer's own with a customer slot (the portal) are the
  base query's; the `tab` (*Waiting on me* · *Asked by me* · *All*) is
  access and stays a parameter, checked per row. This narrows the rest, in
  SQL — `due` too, which ran in memory.

  | Field | Operators | Is |
  |---|---|---|
  | `kind` | `$EQUAL` `$IN` | the approval's kind (`approval_kinds`) |
  | `state` | `$EQUAL` `$IN` | its state (`approval_states`) |
  | `customer_id` | `$EQUAL` `$IN` | the customer it is about |
  | `lead_id` | `$EQUAL` `$IN` | the lead it is about |
  | `due` | `$EQUAL` | `overdue`: pending and past its due time at *now*; `week`: pending and due within seven days of *now* (overdue included) |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      kind: {:approval_kind, ["$EQUAL", "$IN"]},
      state: ["$EQUAL", "$IN"],
      customer_id: ["$EQUAL", "$IN"],
      lead_id: ["$EQUAL", "$IN"]
    ],
    overrideable: ["due"],
    ignoreable: [
      due: ["", nil],
      kind: ["", nil, []],
      state: ["", nil, []],
      customer_id: ["", nil, []],
      lead_id: ["", nil, []]
    ]

  use Data.Filters, operators: [due: ["$EQUAL"]]

  import Ecto.Query

  @impl Data.Filters
  def prepare("due", "$EQUAL", value, %{now: %DateTime{} = now})
      when value in ["overdue", "week"],
      do: {:ok, {String.to_existing_atom(value), now}}

  def prepare(_field, _op, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("due", "$EQUAL", {:overdue, now}),
    do: dynamic([a], a.state == :pending and a.due_at < ^now)

  def override_buildable("due", "$EQUAL", {:week, now}) do
    week = DateTime.add(now, 7 * 86_400, :second)
    dynamic([a], a.state == :pending and not is_nil(a.due_at) and a.due_at <= ^week)
  end

  def override_buildable(_field, _operator, _value), do: nil
end
