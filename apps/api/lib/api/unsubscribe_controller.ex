defmodule Api.UnsubscribeController do
  @moduledoc """
  `POST /unsubscribe` at the root (AQ-10B §11.4), with no sign-in: the
  token from the body (`{token}`) or the query (`?token=`, as the
  `List-Unsubscribe` header gives it, where RFC 8058's one-click client
  posts `List-Unsubscribe=One-Click` as a form). 200 `{group, label}`; 410
  `token_invalid`. `Core.Notifications.Unsubscribe` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.Unsubscribe

  action_fallback ApiShared.FallbackController

  def create(conn, params) do
    with {:ok, answer} <- Unsubscribe.run(params["token"], Clock.now()), do: json(conn, answer)
  end
end
