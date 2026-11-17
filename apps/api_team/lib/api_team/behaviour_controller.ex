defmodule ApiTeam.BehaviourController do
  @moduledoc """
  Behaviour in the console (AQ-10 §11.4): the list, a subject's page and
  its timeline, *Log an observation*, and *Forget*. `Core.Behaviour`
  decides; `ApiShared.BehaviourJSON` lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.BehaviourJSON
  alias ApiShared.ConversationsJSON
  alias Core.Behaviour
  alias Core.Behaviour.{Log, Privacy}
  alias Core.Clock

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Behaviour.list(conn.assigns.scope, params, Clock.now()),
         do: json(conn, BehaviourJSON.list(page))
  end

  def show(conn, %{"kind" => kind, "id" => id}) do
    with {:ok, page} <- Behaviour.page(conn.assigns.scope, kind, id, Clock.now()),
         do: json(conn, BehaviourJSON.page(page))
  end

  def observations(conn, %{"kind" => kind, "id" => id} = params) do
    with {:ok, page} <- Behaviour.observations(conn.assigns.scope, kind, id, params),
         do: json(conn, BehaviourJSON.observations(page))
  end

  def create_observation(conn, params) do
    with {:ok, observation} <- Log.manual(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(BehaviourJSON.observation(observation))
    end
  end

  def forget_contact(conn, %{"id" => id}) do
    with {:ok, contact} <- Privacy.forget_contact(conn.assigns.scope, id, Clock.now()),
         do: json(conn, ConversationsJSON.contact(contact))
  end

  def forget_people(conn, %{"id" => id}) do
    with {:ok, answer} <- Privacy.forget_people(conn.assigns.scope, id, Clock.now()),
         do: json(conn, BehaviourJSON.forgotten(answer))
  end
end
