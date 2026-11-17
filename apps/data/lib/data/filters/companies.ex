defmodule Data.Filters.Companies do
  @moduledoc """
  `GET /team/v1/companies`'s `$where` (the job form's picker, AQ-03 §7.1;
  AQ-11B §3 #12). The organisation's companies, at most 20 by name, are the
  base query's (`Data.Companies.search/2`).

  | Field | Operators | Is |
  |---|---|---|
  | `q` | `$ILIKE` | the words, normalised: the name by prefix, substring or trigram |
  """

  use FatEcto.Query.Dynamics.Buildable,
    overrideable: ["q"],
    ignoreable: [q: ["", "%%", nil]]

  use Data.Filters, operators: [q: ["$ILIKE"]]

  import Ecto.Query

  alias Data.Companies.Company

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context) do
    with {:ok, text} <- Data.Filters.words(value), do: {:ok, Company.normalize(text)}
  end

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", qn) when is_binary(qn) and qn != "" do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"
    dynamic([c], like(c.name_normalized, ^like) or fragment("? % ?", c.name_normalized, ^qn))
  end

  def override_buildable(_field, _operator, _value), do: nil
end
