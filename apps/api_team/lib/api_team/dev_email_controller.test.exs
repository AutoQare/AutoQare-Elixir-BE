defmodule ApiTeam.DevEmailControllerTest do
  @moduledoc """
  The gallery and the run's check route (AQ-10B §11.4), dev servers only:
  the routes aren't compiled into the suite (`dev_routes` is dev.exs's),
  so the actions are called as the router would call them.
  """

  use ApiTeam.TeamCase, async: true

  defp conn(path), do: Plug.Test.conn(:get, path) |> Phoenix.Controller.put_format("json")

  test "GET /dev/emails is an HTML index; /dev/emails/:kind renders HTML or plain text; 404 unknown" do
    index = ApiTeam.DevEmailController.index(conn("/dev/emails"), %{})
    assert index.status == 200
    assert index.resp_body =~ "AutoQare emails"

    html =
      ApiTeam.DevEmailController.show(conn("/dev/emails/tasks.assigned"), %{
        "kind" => "tasks.assigned",
        "audience" => "customer",
        "format" => "html"
      })

    assert html.status == 200 and html.resp_body =~ "<!DOCTYPE html>"

    text =
      ApiTeam.DevEmailController.show(conn("/dev/emails/tasks.assigned"), %{
        "kind" => "tasks.assigned",
        "format" => "text"
      })

    assert text.status == 200 and text.resp_body =~ "Manage notifications:"

    # The action answers the fallback's 404.
    assert ApiTeam.DevEmailController.show(conn("/dev/emails/nope"), %{"kind" => "nope.kind"}) ==
             {:error, :not_found}
  end

  test "GET /team/v1/dev/notifications?since= lists who was told, with deliveries" do
    c = board_cast_fixture()

    {:ok, _} =
      Core.Notifications.ensure(Data.Scope.system(c.org), %{
        user_id: c.fiza.id,
        notification_kind_key: "tasks.assigned",
        title: "A task",
        dedupe_key: "dev-log"
      })

    conn =
      conn("/v1/dev/notifications")
      |> Plug.Conn.assign(:scope, scope_for(c.hira))
      |> ApiTeam.DevController.notifications(%{"since" => "2000-01-01T00:00:00Z"})

    assert [%{"kind" => "tasks.assigned", "to" => to, "audience" => "staff", "deliveries" => []}] =
             Jason.decode!(conn.resp_body)

    assert to == c.fiza.email
  end
end
