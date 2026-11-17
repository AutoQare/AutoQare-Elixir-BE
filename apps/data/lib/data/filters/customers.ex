defmodule Data.Filters.Customers do
  @moduledoc """
  `GET /team/v1/customers`'s `$where` (AQ-11B §3 #11). Which customers the
  caller may see — every one for the system admin, the caller's teams'
  otherwise, `team_id` (the scope, a plain parameter) narrowing within that
  — and that archived ones stay out are the base query's
  (`Data.Customers.filtered/4`); this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `status` | `$EQUAL` `$IN` | the customer's status (`customer_statuses`) |
  | `q` | `$ILIKE` | the words: the display name or the email, by substring |
  | `mine` | `$EQUAL` | `true`: a customer with a profile the person asking owns (a `profile_members` row); `false`: none |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [status: ["$EQUAL", "$IN"]],
    overrideable: ["q", "mine"],
    ignoreable: [status: ["", nil, []], q: ["", "%%", nil], mine: ["", nil]]

  use Data.Filters, operators: [q: ["$ILIKE"], mine: ["$EQUAL"]]

  import Ecto.Query

  alias Data.Customers.{Profile, ProfileMember}
  alias Data.Filters

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context), do: Filters.words(value)

  def prepare("mine", "$EQUAL", value, %{user_id: me}) when is_binary(me) do
    with {:ok, mine?} <- Filters.boolean(value), do: {:ok, {mine?, me}}
  end

  def prepare("mine", _operator, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", text) when is_binary(text) do
    like = "%" <> escape(text) <> "%"
    dynamic([c], ilike(c.display_name, ^like) or ilike(c.email, ^like))
  end

  def override_buildable("mine", "$EQUAL", {mine?, me}) do
    owned =
      from(p in Profile,
        join: pm in ProfileMember,
        on: pm.profile_id == p.id,
        where: pm.user_id == ^me,
        select: p.customer_id
      )

    if mine?,
      do: dynamic([c], c.id in subquery(owned)),
      else: dynamic([c], c.id not in subquery(owned))
  end

  def override_buildable(_field, _operator, _value), do: nil

  # The words as they are: `%`, `_` and `\` match themselves.
  defp escape(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")
end
