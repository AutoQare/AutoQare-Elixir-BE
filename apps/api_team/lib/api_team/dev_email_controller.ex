defmodule ApiTeam.DevEmailController do
  @moduledoc """
  The email gallery (AQ-10B §7.3, §11.4), at the root on a **dev server
  only** (`Api.Router` compiles it in with `dev_routes`): `GET /dev/emails`
  is an HTML index linking every template × audience × format, and `GET
  /dev/emails/:kind?audience=staff|customer&format=html|text&no_login=1`
  one rendered with sample data. `Notifire.Emails.Gallery` renders.
  """

  use Phoenix.Controller, formats: [:html, :json]

  alias Notifire.Emails.Gallery

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Gallery.index("/dev/emails"))
  end

  def show(conn, %{"kind" => kind} = params) do
    audience = if params["audience"] == "customer", do: "customer", else: "staff"
    text? = params["format"] == "text"

    case Gallery.render(kind, audience, params["no_login"] in ["1", "true"]) do
      nil ->
        {:error, :not_found}

      %{text: text} when text? ->
        conn |> put_resp_content_type("text/plain") |> send_resp(200, text)

      %{html: html} ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, html)
    end
  end
end
