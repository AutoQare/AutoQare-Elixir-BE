defmodule ApiTeam.LeadWatchController do
  @moduledoc """
  *Watch* a lead (AQ-10B §11.4, QP10b-15): `POST /leads/:id/watch` and
  `DELETE /leads/:id/watch`, 204. `Core.Notifications.LeadWatch` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.LeadWatch

  action_fallback ApiShared.FallbackController

  def watch(conn, %{"id" => id}) do
    with :ok <- LeadWatch.set(conn.assigns.scope, id, true, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  def unwatch(conn, %{"id" => id}) do
    with :ok <- LeadWatch.set(conn.assigns.scope, id, false, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
