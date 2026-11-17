defmodule Data.Filters.Contacts do
  @moduledoc """
  `GET /team/v1/contacts`'s `$where` (AQ-11B §3 #7). The organisation's
  live contacts (not merged) are the base query's; this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `company_id` | `$EQUAL` `$IN` `$NULL` `$NOT_NULL` | the contact's company |
  | `q` | `$ILIKE` | the words, normalised: a name by substring or trigram, or a handle's value by substring |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [company_id: ["$EQUAL", "$IN", "$NULL", "$NOT_NULL"]],
    overrideable: ["q"],
    ignoreable: [q: ["", "%%", nil], company_id: ["", nil, []]]

  use Data.Filters, operators: [q: ["$ILIKE"]]

  import Ecto.Query

  alias Data.Contacts.{Contact, Handle}

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context) do
    with {:ok, text} <- Data.Filters.words(value), do: {:ok, Contact.normalize(text)}
  end

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", qn) when is_binary(qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"
    handle = from(h in Handle, where: like(h.value_normalized, ^like), select: h.contact_id)

    dynamic(
      [c],
      like(c.name_normalized, ^like) or fragment("? % ?", c.name_normalized, ^qn) or
        c.id in subquery(handle)
    )
  end

  def override_buildable(_field, _operator, _value), do: nil
end
