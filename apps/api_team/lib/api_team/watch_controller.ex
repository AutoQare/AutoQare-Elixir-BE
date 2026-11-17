defmodule ApiTeam.WatchController do
  @moduledoc """
  A person's own watches (AQ-10 §8, §11.4): the list, *Watch* (201, or
  200 for the same subject and trigger, its settings updated), the sheet's
  changes and *Pause*, *Remove*. Another person's is not found.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.BehaviourJSON
  alias Core.Clock
  alias Core.Watches

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    with {:ok, list} <- Watches.list(conn.assigns.scope, Clock.now()),
         do: json(conn, BehaviourJSON.watches(list))
  end

  def create(conn, params) do
    case Watches.create(conn.assigns.scope, params, Clock.now()) do
      {:ok, {:created, watch}} -> conn |> put_status(:created) |> json(BehaviourJSON.watch(watch))
      {:ok, {:updated, watch}} -> json(conn, BehaviourJSON.watch(watch))
      error -> error
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, watch} <-
           Watches.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, BehaviourJSON.watch(watch))
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Watches.delete(conn.assigns.scope, id), do: send_resp(conn, :no_content, "")
  end
end
