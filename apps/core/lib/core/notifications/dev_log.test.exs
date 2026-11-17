defmodule Core.Notifications.DevLogTest do
  @moduledoc "The run's check route (AQ-10B §11.4): who was told what since a moment."

  use Core.CoreCase, async: true

  alias Core.Notifications.CustomerMail
  alias Core.Notifications.DevLog

  @now ~U[2026-11-14 09:00:00.000000Z]

  test "the organisation's rows since then, with their audience and deliveries, then the customer mail" do
    c = board_cast_fixture()
    push_subscription_fixture(c.fiza)

    {:ok, _} =
      Core.Notifications.ensure(
        Data.Scope.system(c.org),
        %{
          user_id: c.fiza.id,
          notification_kind_key: "tasks.assigned",
          title: "A task",
          dedupe_key: "a"
        },
        @now
      )

    :written =
      CustomerMail.write(
        c.sara,
        %{kind: "leads.weekly_report", subject: "Your week", text: "x", dedupe: "w"},
        @now
      )

    {:ok, rows} = DevLog.since(scope_for(c.hira), "2000-01-01T00:00:00Z")

    assert [
             %{
               kind: "tasks.assigned",
               audience: "staff",
               title: "A task",
               deliveries: [%{channel: :push, state: :pending, deferred: false, skip_reason: nil}]
             } = told,
             %{kind: "leads.weekly_report", audience: "customer_no_login", state: :pending}
           ] = rows

    assert told.to == c.fiza.email
    assert {:error, {:invalid, %{"since" => _}}} = DevLog.since(scope_for(c.hira), "yesterday")
  end
end
