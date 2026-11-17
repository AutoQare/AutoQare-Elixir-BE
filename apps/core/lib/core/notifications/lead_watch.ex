defmodule Core.Notifications.LeadWatch do
  @moduledoc """
  *Watch* on a lead (AQ-10B §6, §11.4, QP10b-15): a staff member told of
  the lead's replies and moves as its owner is. `POST /leads/:id/watch` ·
  `DELETE` (team), 204: anyone who can read the lead may watch it; a
  customer gets `not_found`. The lead sheet carries `watching` and
  `watchers_count`.
  """

  alias Core.Leads
  alias Data.Notifications.LeadWatchers
  alias Data.Scope

  @doc "`POST /leads/:id/watch` (`on?` true) or `DELETE` (false): `:ok`."
  @spec set(Scope.t(), term(), boolean(), DateTime.t()) :: :ok | {:error, term()}
  def set(%Scope{} = scope, id, on?, %DateTime{} = now) do
    with true <-
           (not Scope.customer?(scope) and Scope.user_id(scope) != nil) || {:error, :not_found},
         {:ok, lead} <- Leads.fetch(scope, :read, id) do
      if on?,
        do: LeadWatchers.watch(lead.id, Scope.user_id(scope), now),
        else: LeadWatchers.unwatch(lead.id, Scope.user_id(scope))
    end
  end

  @doc "`%{watching, watchers_count}` of one lead for the scope's person."
  @spec summary(Scope.t(), binary()) :: %{watching: boolean(), watchers_count: non_neg_integer()}
  def summary(%Scope{} = scope, lead_id) do
    {count, watching?} =
      [lead_id] |> LeadWatchers.summary(Scope.user_id(scope)) |> Map.get(lead_id, {0, false})

    %{watching: watching?, watchers_count: count}
  end

  @doc "The lead's watchers (user ids)."
  @spec watchers(binary()) :: [binary()]
  def watchers(lead_id), do: LeadWatchers.watchers(lead_id)
end
