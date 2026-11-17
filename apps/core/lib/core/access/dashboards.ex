defmodule Core.Access.Dashboards do
  @moduledoc """
  Who reads which dashboard (AQ-11 §6, QP11-10), **pure**: the
  `{:dashboard, d}` rows of `Core.Access`. *My numbers* (`:me`) is every
  staff member's own; *Team* (`%{team_id}`) a team lead's for the teams
  they lead, and the system admin's; *All teams* (`:all`) the system
  admin's. Anyone else, a customer included, finds nothing.
  """

  alias Data.Scope

  @doc "The decision for `:read` on a dashboard."
  @spec decide(Scope.t(), atom(), :me | :all | map()) :: :ok | {:error, :not_found}
  def decide(scope, :read, :me), do: found(Scope.staff?(scope))
  def decide(scope, :read, :all), do: found(Scope.admin?(scope))

  def decide(scope, :read, %{team_id: team_id}),
    do: found(Scope.admin?(scope) or Scope.team_role(scope, team_id) == :lead)

  def decide(_scope, _action, _dashboard), do: {:error, :not_found}

  defp found(true), do: :ok
  defp found(false), do: {:error, :not_found}
end
