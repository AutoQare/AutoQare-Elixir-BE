defmodule Data.Filters.Invitations do
  @moduledoc """
  `GET /team/v1/invitations`' `$where` (AQ-11B §3 #12). Whose invitations
  the caller may see — all for the system admin; a team lead's teams'
  members and the customers those teams serve — is the base query's
  (`Data.Invitations.list/4`); this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `state` | `$EQUAL` | `"open"`: not accepted, not revoked, not expired at *now*; `"past"`: accepted, revoked or expired (the *Past* tab) |
  | `kind` | `$EQUAL` `$IN` | `admin` · `team_member` · `customer` |
  | `team_id` | `$EQUAL` `$IN` | the team a member is invited to |
  | `customer_id` | `$EQUAL` `$IN` | the customer invited to the portal |
  | `q` | `$ILIKE` | the words: the email or the invited name, by substring |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      kind: ["$EQUAL", "$IN"],
      team_id: ["$EQUAL", "$IN"],
      customer_id: ["$EQUAL", "$IN"]
    ],
    overrideable: ["state", "q"],
    ignoreable: [
      state: ["", nil],
      q: ["", "%%", nil],
      kind: ["", nil, []],
      team_id: ["", nil, []],
      customer_id: ["", nil, []]
    ]

  use Data.Filters, operators: [state: ["$EQUAL"], q: ["$ILIKE"]]

  import Ecto.Query

  alias Data.Filters

  @impl Data.Filters
  def prepare("state", "$EQUAL", state, %{now: %DateTime{} = now}) when state in ~w(open past),
    do: {:ok, {String.to_existing_atom(state), now}}

  def prepare("state", _operator, _value, _context), do: :error
  def prepare("q", "$ILIKE", value, _context), do: Filters.words(value)

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("state", "$EQUAL", {:open, now}),
    do: dynamic([i], is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^now)

  def override_buildable("state", "$EQUAL", {:past, now}),
    do:
      dynamic(
        [i],
        not is_nil(i.accepted_at) or not is_nil(i.revoked_at) or i.expires_at <= ^now
      )

  def override_buildable("q", "$ILIKE", text) when is_binary(text) do
    like = "%" <> escape(text) <> "%"
    dynamic([i], ilike(i.email, ^like) or ilike(i.invited_name, ^like))
  end

  def override_buildable(_field, _operator, _value), do: nil

  # The words as they are: `%`, `_` and `\` match themselves.
  defp escape(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")
end
