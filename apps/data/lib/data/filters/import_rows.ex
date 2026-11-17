defmodule Data.Filters.ImportRows do
  @moduledoc """
  An import's rows' `$where` (`GET /team/v1/imports/:id/rows`, AQ-12
  §11.4): the import's rows are the base query's (`Data.Imports.rows_page/4`,
  by tab and row number); this narrows them to a preview tab.

  | Field | Operators | Is |
  |---|---|---|
  | `result` | `$EQUAL` `$IN` | what the dry run made of the row (`import_row_results`: `new · update · duplicate · error · skipped`) |
  | `tab` | `$EQUAL` | the file's tab, by its name |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [result: ["$EQUAL", "$IN"], tab: ["$EQUAL"]],
    ignoreable: [result: ["", nil, []], tab: ["", nil]]

  use Data.Filters
end
