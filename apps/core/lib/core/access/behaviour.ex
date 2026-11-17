defmodule Core.Access.Behaviour do
  @moduledoc """
  Who sees and does what in Behaviour (AQ-10 §4, QP10-14, QP10-17),
  **pure**: the `{:behaviour, _}` and `{:watch, _}` rows of `Core.Access`.

  | Subject | Carries |
  |---|---|
  | `{:behaviour, s}` | `organisation_id`, `team_ids` (the teams that touch the company or contact: its jobs, leads or conversations; `Data.Behaviour.team_ids/1`) |
  | `{:watch, w}` | `organisation_id`, `user_id` (its owner) |

  - **`:read`, `:observe`, `:watch`**: every staff member of a team that
    touches the subject; the system admin, all. Anyone else — another
    team, a customer, another organisation — finds nothing.
  - **`:forget`**: a team lead of a team that touches the subject, or the
    system admin; staff who see it are refused with
    `:forget_not_allowed` ("Only a team lead can forget someone.", 403).
  - **A watch is its owner's own** (PLAN §3): anyone else's is not found,
    the system admin's view included.
  """

  alias Data.Scope

  @doc "Every action a subject answers, for the matrix."
  def actions, do: [:read, :observe, :watch, :forget]

  @spec decide(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide(%Scope{} = scope, action, subject) do
    if sees?(scope, subject),
      do: act(scope, action, Map.get(subject, :team_ids, [])),
      else: {:error, :not_found}
  end

  # Staff of a team that touches it, or the system admin; never a customer.
  defp sees?(scope, subject) do
    same_organisation?(scope, subject) and not Scope.customer?(scope) and Scope.staff?(scope) and
      (Scope.admin?(scope) or
         Enum.any?(Map.get(subject, :team_ids, []), &Scope.team_role(scope, &1)))
  end

  defp act(_scope, action, _team_ids) when action in [:read, :observe, :watch], do: :ok

  defp act(scope, :forget, team_ids) do
    if Scope.admin?(scope) or Enum.any?(team_ids, &(Scope.team_role(scope, &1) == :lead)),
      do: :ok,
      else: {:error, :forget_not_allowed}
  end

  defp act(_scope, _action, _team_ids), do: {:error, :not_found}

  @doc "A watch: its owner's alone."
  @spec decide_watch(Scope.t(), atom(), map()) :: :ok | {:error, :not_found}
  def decide_watch(%Scope{} = scope, _action, watch) do
    own? =
      not Scope.customer?(scope) and Scope.staff?(scope) and same_organisation?(scope, watch) and
        not is_nil(Scope.user_id(scope)) and watch.user_id == Scope.user_id(scope)

    if own?, do: :ok, else: {:error, :not_found}
  end

  defp same_organisation?(scope, %{organisation_id: org_id}) when is_binary(org_id),
    do: org_id == Scope.organisation_id(scope)

  defp same_organisation?(_scope, _subject), do: true
end
