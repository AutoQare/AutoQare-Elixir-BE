defmodule Data.Filters.People do
  @moduledoc """
  `GET /team/v1/people`'s `$where` (AQ-11B §3 #12). Who the caller may see
  — every staff person for the system admin, their own teams' people for
  anyone else, `team_id` narrowing within that — is the base query's
  (`Data.Teams.people/4`, the user as the root, the person as `:person`);
  this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `q` | `$ILIKE` | the words: the name or the email, by substring |
  | `suspended` | `$EQUAL` | `true`: suspended (`suspended_at` set); `false`: not |
  | `admin` | `$EQUAL` | `true`: the organisation's system admin; `false`: everyone else |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [],
    overrideable: ["q", "suspended", "admin"],
    ignoreable: [q: ["", "%%", nil], suspended: ["", nil], admin: ["", nil]]

  use Data.Filters, operators: [q: ["$ILIKE"], suspended: ["$EQUAL"], admin: ["$EQUAL"]]

  import Ecto.Query

  alias Data.Filters
  alias Data.Organisations.OrgAdmin

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context), do: Filters.words(value)
  def prepare("suspended", "$EQUAL", value, _context), do: Filters.boolean(value)

  def prepare("admin", "$EQUAL", value, context) do
    with {:ok, admin?} <- Filters.boolean(value),
         do: {:ok, {admin?, Map.get(context, :organisation_id)}}
  end

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", text) when is_binary(text) do
    like = "%" <> escape(text) <> "%"
    dynamic([u, person: p], ilike(p.display_name, ^like) or ilike(u.email, ^like))
  end

  def override_buildable("suspended", "$EQUAL", true),
    do: dynamic([u], not is_nil(u.suspended_at))

  def override_buildable("suspended", "$EQUAL", false), do: dynamic([u], is_nil(u.suspended_at))

  def override_buildable("admin", "$EQUAL", {admin?, organisation_id}) do
    admins = from(a in OrgAdmin, where: a.organisation_id == ^organisation_id, select: a.user_id)

    if admin?,
      do: dynamic([u], u.id in subquery(admins)),
      else: dynamic([u], u.id not in subquery(admins))
  end

  def override_buildable(_field, _operator, _value), do: nil

  # The words as they are: `%`, `_` and `\` match themselves.
  defp escape(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")
end
