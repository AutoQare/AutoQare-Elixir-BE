defmodule Core.Notifications.MutesTest do
  @moduledoc """
  Mutes (AQ-10B §11.4, QP10b-3): a muted customer writes no row for that
  person about their leads, tasks, approvals and meetings — except a
  mention, an approval asked of them and a meeting about to start; staff
  only; the customer shape's `muted`.
  """

  use Core.CoreCase, async: true

  alias Core.Notifications
  alias Core.Notifications.Mutes

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    task = task_fixture(scope_for(c.hira), customer: c.tanweer, primary: c.fiza)
    Map.put(c, :task, task)
  end

  defp ensure(c, kind, extra) do
    Notifications.ensure(
      Data.Scope.system(c.org),
      Map.merge(
        %{
          user_id: c.fiza.id,
          notification_kind_key: kind,
          title: "Something about Tanweer",
          dedupe_key: "#{kind}:#{System.unique_integer([:positive])}"
        },
        extra
      ),
      @now
    )
  end

  test "a muted customer: no row about their task, except a mention", c do
    :ok = Mutes.customer(scope_for(c.fiza), c.tanweer.id, true, @now)

    assert {:ok, %{is_new: false, id: nil}} = ensure(c, "tasks.commented", %{task_id: c.task.id})
    assert {:ok, %{is_new: true}} = ensure(c, "tasks.mentioned", %{task_id: c.task.id})

    # Someone else's rows are untouched.
    assert {:ok, %{is_new: true}} =
             Notifications.ensure(Data.Scope.system(c.org), %{
               user_id: c.qasim.id,
               notification_kind_key: "tasks.commented",
               task_id: c.task.id,
               title: "x",
               dedupe_key: "other"
             })

    :ok = Mutes.customer(scope_for(c.fiza), c.tanweer.id, false, @now)
    assert {:ok, %{is_new: true}} = ensure(c, "tasks.commented", %{task_id: c.task.id})
  end

  test "staff only; the customer shape says whether I muted them", c do
    assert Mutes.customer(customer_scope_for(c.tanweer), c.tanweer.id, true, @now) ==
             {:error, :not_found}

    :ok = Mutes.customer(scope_for(c.fiza), c.tanweer.id, true, @now)
    :ok = Mutes.customer(scope_for(c.fiza), c.tanweer.id, true, @now)

    assert {:ok, %{muted: true}} = Core.Customers.get(scope_for(c.fiza), c.tanweer.id)
    assert {:ok, %{muted: false}} = Core.Customers.get(scope_for(c.qasim), c.tanweer.id)
    assert {:ok, %{muted: nil}} = Core.Customers.get(customer_scope_for(c.tanweer), c.tanweer.id)
  end
end
