defmodule Data.Filters.History do
  @moduledoc """
  The lead page's History `$where` (`GET /team/v1/leads/:id/history`,
  AQ-04B §8.1, AQ-11B §3 #12). One lead's ledger is the base query's
  (`Data.Leads.history/3`, newest first, its `before` keyset); this narrows
  it. The chips (*Moves*, *Notes*, *Tasks*, *Follow-ups*, *System*) are
  the client's groupings of the kinds.

  | Field | Operators | Is |
  |---|---|---|
  | `kind` | `$EQUAL` `$IN` `$NOT_IN` | `lead_event_kinds` |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [kind: ["$EQUAL", "$IN", "$NOT_IN"]],
    ignoreable: [kind: ["", nil, []]]

  use Data.Filters, operators: []
end
