defmodule Api.UnsubscribeControllerTest do
  @moduledoc """
  `POST /unsubscribe` at the root (AQ-10B §11.4): no sign-in; the token in
  the body, or in the query as RFC 8058's one-click client posts it; 200
  `{group, label}`, 410 `token_invalid`; answered across origins for the
  apps' page, preflight included.
  """

  use Api.ConnCase, async: true

  alias Data.Notifications.Preferences
  alias Data.Notifications.Unsubscribe

  test "a JSON body's token turns the group's email off: 200 {group, label}", %{conn: conn} do
    user = user_fixture()
    token = Unsubscribe.sign(user.id, "approvals", Utils.Clock.now())

    conn = post(conn, "/unsubscribe", %{token: token})

    assert json_response(conn, 200) == %{"group" => "approvals", "label" => "Approvals"}
    assert %{email: false} = Preferences.switches(user.id, "approvals")
  end

  test "RFC 8058's one-click: the token in the query, List-Unsubscribe=One-Click as a form",
       %{conn: conn} do
    user = user_fixture()
    token = Unsubscribe.sign(user.id, "tasks", Utils.Clock.now())

    conn =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/unsubscribe?token=#{URI.encode_www_form(token)}", "List-Unsubscribe=One-Click")

    assert %{"group" => "tasks"} = json_response(conn, 200)
  end

  test "a forged token is 410 token_invalid", %{conn: conn} do
    conn = post(conn, "/unsubscribe", %{token: "forged"})
    assert %{"error" => %{"code" => "token_invalid"}} = json_response(conn, 410)
  end

  test "the apps' page may post it from the browser: CORS for the console and the portal",
       %{conn: conn} do
    for origin <- ["http://localhost:5800", "http://localhost:5801"] do
      preflight =
        conn
        |> put_req_header("origin", origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> options("/unsubscribe")

      assert preflight.status == 204
      assert get_resp_header(preflight, "access-control-allow-origin") == [origin]

      answered =
        build_conn()
        |> put_req_header("origin", origin)
        |> post("/unsubscribe", %{token: "forged"})

      assert get_resp_header(answered, "access-control-allow-origin") == [origin]
    end
  end
end
