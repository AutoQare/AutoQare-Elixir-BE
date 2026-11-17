defmodule ApiTeam.MuteController do
  @moduledoc """
  *Mute* a lead or a customer's whole pipeline (AQ-10B §11.4, QP10b-3):
  `POST` and `DELETE` `/leads/:id/mute` and `/customers/:id/mute`, 204.
  `Core.Notifications.Mutes` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.Mutes

  action_fallback ApiShared.FallbackController

  def mute_lead(conn, %{"id" => id}),
    do: done(conn, Mutes.lead(conn.assigns.scope, id, true, Clock.now()))

  def unmute_lead(conn, %{"id" => id}),
    do: done(conn, Mutes.lead(conn.assigns.scope, id, false, Clock.now()))

  def mute_customer(conn, %{"id" => id}),
    do: done(conn, Mutes.customer(conn.assigns.scope, id, true, Clock.now()))

  def unmute_customer(conn, %{"id" => id}),
    do: done(conn, Mutes.customer(conn.assigns.scope, id, false, Clock.now()))

  defp done(conn, :ok), do: send_resp(conn, :no_content, "")
  defp done(_conn, error), do: error
end
