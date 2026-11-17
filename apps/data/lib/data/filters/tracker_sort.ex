defmodule Data.Filters.TrackerSort do
  @moduledoc """
  The Tracker's `$order` (AQ-04B §8.1, AQ-11B §11.4): one column of
  `tracker_columns`, `$ASC` or `$DESC`; without one, last activity, newest
  first. **Nothing sorts last either way** (`NULLS LAST`), and ties go by
  id (`Data.Leads.for_team/4` adds it), so pages never overlap. Text sorts
  lower-cased, byte by byte (`COLLATE "C"`), as Elixir compares it.

  | Column | Key |
  |---|---|
  | `applied` | `applied_at` |
  | `title` · `company` · `customer` · `profile` · `owner` | the name, lower-cased |
  | `source` · `outcome` · `workplace` · `engagement` | the key |
  | `state` | the state's place (To do, In progress, On hold, Done), then the stage's position |
  | `last_activity` | `last_activity_at` |
  | `money` | the job's currency, then its lower amount (else its upper) |
  | `cv` | the CV's label, then its version |
  | `next` · `labels` · `missing` | **in memory**: they are computed on read (`Core.Leads.Signals`, the row's *Missing*) and have no SQL form, so `Core.Leads.Tracker` sorts the rows itself; here they build nothing |

  The bindings are `Data.Leads.team_query/1`'s.
  """

  use FatEcto.Sort.Sortable,
    sortable: [],
    overrideable: ~w(applied title company source customer profile owner state outcome next
                     last_activity money workplace engagement cv labels missing)

  use Data.Filters,
    operators: [
      applied: ["$ASC", "$DESC"],
      title: ["$ASC", "$DESC"],
      company: ["$ASC", "$DESC"],
      source: ["$ASC", "$DESC"],
      customer: ["$ASC", "$DESC"],
      profile: ["$ASC", "$DESC"],
      owner: ["$ASC", "$DESC"],
      state: ["$ASC", "$DESC"],
      outcome: ["$ASC", "$DESC"],
      next: ["$ASC", "$DESC"],
      last_activity: ["$ASC", "$DESC"],
      money: ["$ASC", "$DESC"],
      workplace: ["$ASC", "$DESC"],
      engagement: ["$ASC", "$DESC"],
      cv: ["$ASC", "$DESC"],
      labels: ["$ASC", "$DESC"],
      missing: ["$ASC", "$DESC"]
    ]

  import Ecto.Query

  @in_memory ~w(next labels missing)

  @doc "The columns `Core.Leads.Tracker` sorts in memory."
  @spec in_memory() :: [String.t()]
  def in_memory, do: @in_memory

  @impl FatEcto.Sort.Sortable
  def override_sortable(column, _dir) when column in @in_memory, do: nil
  def override_sortable(column, dir), do: {nulls_last(dir), key(column)}

  defp nulls_last("$ASC"), do: :asc_nulls_last
  defp nulls_last("$DESC"), do: :desc_nulls_last

  defp key("applied"), do: dynamic([lead: l], l.applied_at)
  defp key("last_activity"), do: dynamic([lead: l], l.last_activity_at)
  defp key("title"), do: dynamic([job: j], fragment(~s|lower(?) COLLATE "C"|, j.title))
  defp key("company"), do: dynamic([company: c], fragment(~s|lower(?) COLLATE "C"|, c.name))

  defp key("customer"),
    do: dynamic([customer: c], fragment(~s|lower(?) COLLATE "C"|, c.display_name))

  defp key("profile"), do: dynamic([profile: p], fragment(~s|lower(?) COLLATE "C"|, p.title))

  defp key("owner"),
    do: dynamic([owner_person: o], fragment(~s|lower(?) COLLATE "C"|, o.display_name))

  defp key("source"), do: dynamic([job: j], fragment(~s|(?)::text COLLATE "C"|, j.source))
  defp key("workplace"), do: dynamic([job: j], fragment(~s|(?)::text COLLATE "C"|, j.workplace))

  defp key("engagement"),
    do: dynamic([job: j], fragment(~s|(?)::text COLLATE "C"|, j.engagement))

  defp key("outcome"), do: dynamic([lead: l], fragment(~s|(?)::text COLLATE "C"|, l.outcome))

  defp key("state") do
    dynamic(
      [lead: l, stage: s],
      fragment(
        "(CASE ? WHEN 'todo' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'on_hold' THEN 2 ELSE 3 END) * 1000000 + coalesce(?, 0)",
        l.state,
        s.position
      )
    )
  end

  # A record sorts by its first field, then its second; a missing amount
  # after the amounts of its currency (as Elixir's tuples sort `nil`).
  defp key("money") do
    dynamic(
      [job: j],
      fragment(
        ~s|CASE WHEN ? IS NULL THEN NULL ELSE ROW((?)::text COLLATE "C", coalesce(?, ?)) END|,
        j.comp_currency,
        j.comp_currency,
        j.comp_min_minor,
        j.comp_max_minor
      )
    )
  end

  defp key("cv") do
    dynamic(
      [document: d],
      fragment(
        ~s|CASE WHEN ? IS NULL THEN NULL ELSE ROW(lower(?) COLLATE "C", ?) END|,
        d.id,
        d.label,
        d.version_no
      )
    )
  end
end
