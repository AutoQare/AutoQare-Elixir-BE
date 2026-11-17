defmodule Data.Filters.TasksSort do
  @moduledoc """
  The tasks board's `$order` (AQ-02 QP2-9, AQ-11B §11.4), one field at a
  time; `Data.Tasks.board/4` adds the ties after it — the due key, then
  the oldest first, then the id — so a column's order never wobbles.

  | Field | Directions | Is |
  |---|---|---|
  | `due` | `$ASC` | due first, soonest first (a day sorts at its end, UTC), no due last — the default |
  | `priority` | `$ASC` | urgent, high, normal (none), low; then by due |
  | `inserted_at` | `$DESC` | the newest first |
  """

  use FatEcto.Sort.Sortable,
    sortable: [inserted_at: ["$DESC"]],
    overrideable: ["due", "priority"]

  use Data.Filters, operators: [due: ["$ASC"], priority: ["$ASC"]]

  import Ecto.Query

  @impl FatEcto.Sort.Sortable
  def override_sortable("due", "$ASC"), do: {:asc_nulls_last, due_key()}

  def override_sortable("priority", "$ASC") do
    {:asc,
     dynamic(
       [t],
       fragment(
         "CASE ? WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'low' THEN 3 ELSE 2 END",
         t.priority
       )
     )}
  end

  def override_sortable(_field, _direction), do: nil

  @doc "When a task is due, as an instant: `due_at`, or the end of `due_on` (UTC); `NULL` for none."
  @spec due_key() :: Ecto.Query.dynamic_expr()
  def due_key do
    dynamic(
      [t],
      fragment(
        "coalesce(?, (? + time '23:59:59.999999') AT TIME ZONE 'UTC')",
        t.due_at,
        t.due_on
      )
    )
  end
end
