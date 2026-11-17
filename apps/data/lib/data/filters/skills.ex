defmodule Data.Filters.Skills do
  @moduledoc """
  `GET /skills`'s `$where` (both apps; AQ-01 §4.3, AQ-11B §3 #12). The
  organisation's live skills, by category then name, are the base query's
  (`Data.Skills.filtered/2`).

  | Field | Operators | Is |
  |---|---|---|
  | `q` | `$ILIKE` | the words: the name by substring, case-insensitive |
  | `category` | `$EQUAL` `$IN` | the skill's category |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [category: ["$EQUAL", "$IN"]],
    overrideable: ["q"],
    ignoreable: [q: ["", "%%", nil], category: [[], "", nil]]

  use Data.Filters, operators: [q: ["$ILIKE"]]

  import Ecto.Query

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context), do: Data.Filters.words(value)

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", text) when is_binary(text) do
    like = "%" <> Data.Companies.escape_like(text) <> "%"
    dynamic([s], ilike(s.name, ^like))
  end

  def override_buildable(_field, _operator, _value), do: nil
end
