defmodule Data.Filters.Triage do
  @moduledoc """
  The team's Triage `$where` (`GET /team/v1/triage`, AQ-06 §7.3, AQ-11B
  §11.4). The team's conversations linked to no lead and not ignored are
  the base query's (`Data.Conversations.triage/3`); this narrows them.

  | Field | Operators | Is |
  |---|---|---|
  | `profile_owner` | `$EQUAL` | `"me"` or a user id: items on that person's profiles — the owners of the live profiles the receiving channel serves, else of the customer's live profiles (`Data.Dashboards.triage_owner_rows/1`, the rule *To sort in Triage* counts with) |
  """

  use FatEcto.Query.Dynamics.Buildable,
    overrideable: ["profile_owner"],
    ignoreable: [profile_owner: ["", nil]]

  use Data.Filters, operators: [profile_owner: ["$EQUAL"]]

  import Ecto.Query

  @impl Data.Filters
  def prepare("profile_owner", "$EQUAL", value, %{team_id: team_id} = context)
      when is_binary(team_id) do
    with {:ok, user_id} <- Data.Filters.me_or_id(value, context), do: {:ok, {team_id, user_id}}
  end

  def prepare(_field, _op, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("profile_owner", "$EQUAL", {team_id, user_id}) do
    owned =
      from(r in subquery(Data.Dashboards.triage_owner_rows([team_id])),
        where: r.user_id == ^user_id,
        select: r.conversation_id
      )

    dynamic([c], c.id in subquery(owned))
  end

  def override_buildable(_field, _operator, _value), do: nil
end
