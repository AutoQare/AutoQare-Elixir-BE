defmodule ApiTeam.DashboardController do
  @moduledoc """
  The console's *Dashboard* (AQ-11 §7.4): `GET /dashboard/me?period`
  (*My numbers*), `GET /dashboard/team?team_id&period&cohort` (*Team*) and
  `GET /dashboard/team.csv?…the same…` (its members table and funnel,
  UTF-8 with a BOM). `Core.Dashboards` decides and counts.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.DashboardsJSON
  alias Core.Clock
  alias Core.Dashboards

  action_fallback ApiShared.FallbackController

  def me(conn, params) do
    with {:ok, me} <- Dashboards.me(conn.assigns.scope, params, Clock.now()),
         do: json(conn, DashboardsJSON.me(me))
  end

  def team(conn, params) do
    with {:ok, team} <- Dashboards.team(conn.assigns.scope, params, Clock.now()),
         do: json(conn, DashboardsJSON.team(team))
  end

  def team_csv(conn, params) do
    with {:ok, body, filename} <- Dashboards.team_csv(conn.assigns.scope, params, Clock.now()) do
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, body)
    end
  end
end
