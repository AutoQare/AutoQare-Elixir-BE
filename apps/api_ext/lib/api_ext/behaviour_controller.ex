defmodule ApiExt.BehaviourController do
  @moduledoc """
  Behaviour in the side panel (AQ-10 §11.4): the open job's company or
  thread's contact with its summary, the presence observations (201, or
  200 `replayed` for a known `request_id`), and *Watch* (push and the
  extension, a 2-hour cool-down; 201, or 200 for the same subject and
  trigger) and its removal. `Core.Behaviour.Log` and `Core.Watches`
  decide.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.BehaviourJSON
  alias Core.Behaviour.Log
  alias Core.Clock
  alias Core.Watches

  action_fallback ApiShared.FallbackController

  def show(conn, params) do
    with {:ok, found} <- Log.subject(conn.assigns.scope, params, Clock.now()),
         do: json(conn, BehaviourJSON.ext_subject(found))
  end

  def observe(conn, params) do
    case Log.extension(conn.assigns.scope, params, Clock.now()) do
      {:ok, {:created, _id} = answer} ->
        conn |> put_status(:created) |> json(BehaviourJSON.ext_observed(answer))

      {:ok, {:replayed, _id} = answer} ->
        json(conn, BehaviourJSON.ext_observed(answer))

      error ->
        error
    end
  end

  def watch(conn, params) do
    case Log.watch(conn.assigns.scope, params, Clock.now()) do
      {:ok, {:created, watch}} -> conn |> put_status(:created) |> json(BehaviourJSON.watch(watch))
      {:ok, {:updated, watch}} -> json(conn, BehaviourJSON.watch(watch))
      error -> error
    end
  end

  def unwatch(conn, %{"id" => id}) do
    with :ok <- Watches.delete(conn.assigns.scope, id), do: send_resp(conn, :no_content, "")
  end
end
