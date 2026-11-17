defmodule Api.HealthControllerTest do
  @moduledoc """
  DEPLOY-PLAN L7: `GET /health` answers 200 when `SELECT 1` succeeds and 503
  when it does not, with no auth and nothing a stranger could use.
  """

  use Api.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Api.HealthController

  doctest HealthController

  test "answers 200 ok with the database up, with no token", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{"status" => "ok", "db" => "ok", "version" => "0.1.0"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "a database that does not answer is 503 degraded, and the reason stays in the log" do
    reason = %DBConnection.ConnectionError{message: "tcp connect (db.internal:5432): refused"}

    log =
      capture_log(fn ->
        assert {503, body} = HealthController.report({:error, reason}, "42")
        assert body == %{status: "degraded", db: "down", version: "42"}
        refute inspect(body) =~ "db.internal"
      end)

    assert log =~ "db.internal"
  end

  test "Data.Repo.ping/0 says :ok against the test database" do
    assert Data.Repo.ping() == :ok
  end
end
