defmodule ApiTeam.ImportController do
  @moduledoc """
  Data › Import and Settings › Imports (AQ-12 §3, §11.4): the list, an
  import, its rows, and the steps — each step answers **202** with the
  import as it stands while its background job runs, followed live on
  `import_progress`. `Core.Imports` decides who (a team lead of the team,
  or the system admin; anyone else not found) and what.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ImportsJSON
  alias Core.Clock
  alias Core.Imports

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, list} <- Imports.list(conn.assigns.scope, params, Clock.now()),
         do: json(conn, ImportsJSON.list(list))
  end

  def create(conn, params) do
    with {:ok, import} <- Imports.create(conn.assigns.scope, params, Clock.now()),
         do: accepted(conn, import)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, import} <- Imports.get(conn.assigns.scope, id, Clock.now()),
         do: json(conn, ImportsJSON.view(import))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, import} <- Imports.update(conn.assigns.scope, id, params, Clock.now()),
         do: accepted(conn, import)
  end

  def rows(conn, %{"id" => id} = params) do
    with {:ok, page} <- Imports.rows(conn.assigns.scope, id, params),
         do: json(conn, ImportsJSON.rows(page))
  end

  def update_row(conn, %{"id" => id, "row_id" => row_id} = params) do
    with {:ok, row} <- Imports.edit_row(conn.assigns.scope, id, row_id, params, Clock.now()),
         do: json(conn, ImportsJSON.row(row))
  end

  def skip_row(conn, %{"id" => id, "row_id" => row_id}) do
    with {:ok, row} <- Imports.skip_row(conn.assigns.scope, id, row_id, Clock.now()),
         do: json(conn, ImportsJSON.row(row))
  end

  def commit(conn, %{"id" => id}) do
    with {:ok, import} <- Imports.commit(conn.assigns.scope, id, Clock.now()),
         do: accepted(conn, import)
  end

  def undo(conn, %{"id" => id}) do
    with {:ok, import} <- Imports.undo(conn.assigns.scope, id, Clock.now()),
         do: accepted(conn, import)
  end

  defp accepted(conn, import), do: conn |> put_status(:accepted) |> json(ImportsJSON.view(import))
end
