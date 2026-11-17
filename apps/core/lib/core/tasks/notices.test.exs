defmodule Core.Tasks.NoticesTest do
  @moduledoc """
  AQ-10B §5.2's new task events through their verbs: a step ticked done
  by someone else (pushed only when the customer ticked it), the customer
  editing their task, a task archived under its assignees. Never the
  actor.
  """

  use Core.CoreCase, async: true

  import Ecto.Query

  alias Core.Tasks.Act
  alias Core.Tasks.Portal
  alias Core.Tasks.Steps
  alias Data.Notifications.{Deliveries, Notification}

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    board_cast_fixture()
  end

  defp told(user_id, kind) do
    from(n in Notification, where: n.user_id == ^user_id and n.notification_kind_key == ^kind)
    |> Repo.all()
  end

  test "a step ticked done by the customer: the author and assignees told, with push", c do
    push_subscription_fixture(c.fiza)

    task =
      task_fixture(scope_for(c.fiza),
        customer: c.tanweer,
        customer_access: :shared,
        primary: c.qasim,
        title: "Apply to Corvid"
      )

    step = step_fixture(task, title: "Send the CV", is_for_customer: true)

    {:ok, _} = Steps.toggle(customer_scope_for(c.tanweer), task.id, step.id, @now)

    assert [n] = told(c.fiza.id, "tasks.step_done")
    assert n.title == "Tanweer ticked “Send the CV” done"
    assert [%{channel: :push}] = Deliveries.for_notification(n.id)
    assert [_] = told(c.qasim.id, "tasks.step_done")
    assert told(c.tanweer.user_id, "tasks.step_done") == []
  end

  test "a step ticked by staff tells in-app only, never the one who ticked it", c do
    push_subscription_fixture(c.fiza)
    task = task_fixture(scope_for(c.fiza), primary: c.qasim, title: "Shortlist")
    step = step_fixture(task, title: "Find three", assignee: c.qasim)

    {:ok, _} = Steps.toggle(scope_for(c.qasim), task.id, step.id, @now)

    assert [n] = told(c.fiza.id, "tasks.step_done")
    assert Deliveries.for_notification(n.id) == []
    assert told(c.qasim.id, "tasks.step_done") == []
  end

  test "the customer edits their own task: its author and assignees told", c do
    task = task_fixture(customer_scope_for(c.tanweer), title: "My question", primary: c.fiza)

    {:ok, _} =
      Portal.update(
        customer_scope_for(c.tanweer),
        task.id,
        %{"title" => "My better question"},
        @now
      )

    assert [%{title: "Tanweer edited “My better question”"}] =
             told(c.fiza.id, "tasks.customer_changed")
  end

  test "a task archived under its assignees tells them, not the one who archived", c do
    task =
      task_fixture(scope_for(c.hira), primary: c.fiza, secondary: [c.qasim], title: "Old one")

    {:ok, _} = Act.archive(scope_for(c.hira), task.id, @now)

    assert [%{title: "Hira archived “Old one”"}] = told(c.fiza.id, "tasks.removed")
    assert [_] = told(c.qasim.id, "tasks.removed")
    assert told(c.hira.id, "tasks.removed") == []
  end
end
