defmodule Data.Filters.NotificationsTest do
  @moduledoc """
  `Data.Filters.Notifications`: `unread` and `group` against direct
  queries, and the refusals.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Notifications.{Kind, Notification}

  setup do
    org = organisation_fixture()
    user = user_fixture()
    read = notification_fixture(org, user, dedupe_key: "a")
    unread = notification_fixture(org, user, dedupe_key: "b")
    Data.Notifications.mark_read(user.id, read.id, DateTime.utc_now())
    %{user: user, read: read, unread: unread}
  end

  defp ids(c, where) do
    base = from(n in Notification, where: n.user_id == ^c.user.id)
    {:ok, query} = Filters.where(base, Filters.Notifications, where)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(c, condition) do
    from(n in Notification, where: n.user_id == ^c.user.id)
    |> where(^condition)
    |> select([n], n.id)
    |> Repo.all()
    |> Enum.sort()
  end

  test "unread: true is not read yet; false filters nothing", c do
    assert ids(c, %{"unread" => %{"$EQUAL" => "true"}}) ==
             direct(c, dynamic([n], is_nil(n.read_at)))

    assert ids(c, %{"unread" => %{"$EQUAL" => "true"}}) == [c.unread.id]
    assert length(ids(c, %{"unread" => %{"$EQUAL" => false}})) == 2
  end

  test "group: $EQUAL and $IN, the kinds of the group", c do
    kinds = from(k in Kind, where: k.notification_group_key == "tasks", select: k.key)
    tasks = direct(c, dynamic([n], n.notification_kind_key in subquery(kinds)))

    assert ids(c, %{"group" => %{"$EQUAL" => "tasks"}}) == tasks
    assert length(tasks) == 2
    assert ids(c, %{"group" => %{"$IN" => ["leads", "tasks"]}}) == tasks
    assert ids(c, %{"group" => %{"$EQUAL" => "leads"}}) == []
  end

  test "what the list doesn't take is refused, naming the field", c do
    base = from(n in Notification, where: n.user_id == ^c.user.id)

    for {where, field} <- [
          {%{"read_at" => nil}, "read_at"},
          {%{"unread" => %{"$EQUAL" => "1"}}, "unread"},
          {%{"group" => %{"$ILIKE" => "ta"}}, "group"},
          {%{"group" => %{"$EQUAL" => "Tasks; drop"}}, "group"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Notifications, where)
    end
  end
end
