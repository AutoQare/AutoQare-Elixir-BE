defmodule Data.Filters.Behaviour do
  @moduledoc """
  `GET /team/v1/behaviour`'s `$where` (AQ-10 §11.4, AQ-11B §3 #8). The
  list is a union of two parts, the companies and the contacts with
  anything counted, each named `:subject`; the organisation and **the team
  touch** (a subject on the teams' jobs, leads or conversations, from
  `team_id`: the scope, not a filter) are each part's base query
  (`Data.Behaviour.Subjects`). `Data.Filters.where/4` runs once per part,
  the context naming it (`part: :company | :contact`).

  | Field | Operators | Is |
  |---|---|---|
  | `q` | `$ILIKE` | the words, normalised: the subject's name by substring |
  | `kind` | `$EQUAL` `$IN` | `company` · `contact`: which part answers |
  | `watched` | `$EQUAL` | `me`: subjects the caller watches |
  """

  use FatEcto.Query.Dynamics.Buildable,
    overrideable: ["q", "kind", "watched"],
    ignoreable: [q: ["", "%%", nil], kind: [[], "", nil], watched: ["", nil]]

  use Data.Filters, operators: [q: ["$ILIKE"], kind: ["$EQUAL", "$IN"], watched: ["$EQUAL"]]

  import Ecto.Query

  alias Data.Behaviour.Watch
  alias Data.Contacts.Contact
  alias Data.Filters

  @kinds ~w(company contact)
  @columns %{company: :company_id, contact: :contact_id}

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context) do
    with {:ok, text} <- Filters.words(value),
         do: {:ok, text && Data.Companies.escape_like(Contact.normalize(text))}
  end

  def prepare("kind", _operator, value, %{part: part}) when is_map_key(@columns, part) do
    with {:ok, kinds} <- Filters.keys(value, @kinds), do: {:ok, {:part, part in kinds}}
  end

  def prepare("watched", "$EQUAL", "me", %{part: part, user_id: me})
      when is_map_key(@columns, part) and is_binary(me),
      do: {:ok, {:watched_by, me, Map.fetch!(@columns, part)}}

  def prepare(_field, _operator, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", text) when is_binary(text) and text != "" do
    like = "%" <> text <> "%"
    dynamic([subject: s], like(s.name_normalized, ^like))
  end

  def override_buildable("kind", _operator, {:part, true}), do: dynamic([subject: _s], true)
  def override_buildable("kind", _operator, {:part, false}), do: dynamic([subject: _s], false)

  def override_buildable("watched", "$EQUAL", {:watched_by, user_id, column}) do
    mine =
      from(w in Watch,
        where: field(w, ^column) == parent_as(:subject).id and w.user_id == ^user_id
      )

    dynamic([subject: _s], exists(mine))
  end

  def override_buildable(_field, _operator, _value), do: nil
end
