defmodule ApiClient.HomeController do
  @moduledoc "The customer's *Home* (AQ-11 §3.4, §7.4): `GET /home`. `Core.Dashboards` counts."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.DashboardsJSON
  alias Core.Clock
  alias Core.Dashboards

  action_fallback ApiShared.FallbackController

  def show(conn, _params) do
    with {:ok, home} <- Dashboards.home(conn.assigns.scope, Clock.now()),
         do: json(conn, DashboardsJSON.home(home))
  end
end
