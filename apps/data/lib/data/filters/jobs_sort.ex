defmodule Data.Filters.JobsSort do
  @moduledoc """
  `GET /team/v1/jobs`'s `$order` (AQ-03 §7.1): one field, newest first
  when none is sent. Only the directions the pool's keyset pages are
  listed; ties go by id, descending.

  | Field | Directions | Is |
  |---|---|---|
  | `first_seen_at` | `$DESC` | newest first (the default) |
  | `posted_on` | `$DESC` | posted, newest first, unposted last |
  | `money` | `$DESC` | the job's top in one currency, annualised (a project's budget when the money filter's period is `project`), highest first, other currencies and none last |

  **`money`'s key needs the currency**, which a sort override can't take
  (`override_sortable/2` sees a field and a direction): `Core.Jobs.Pool`
  reads it from the money filter, else from the `currency` switch, and
  `Data.JobList` builds that order and its keyset itself.
  """

  use FatEcto.Sort.Sortable,
    sortable: [first_seen_at: ["$DESC"]],
    overrideable: ["posted_on", "money"]

  use Data.Filters, operators: [posted_on: ["$DESC"], money: ["$DESC"]]

  import Ecto.Query

  @impl FatEcto.Sort.Sortable
  def override_sortable("posted_on", "$DESC"), do: {:desc_nulls_last, dynamic([j], j.posted_on)}
  def override_sortable(_field, _direction), do: nil
end
