defmodule Data.Seeds.NotificationsTest do
  use Data.DataCase, async: true

  alias Data.Notifications
  alias Data.Notifications.Kind
  alias Data.Seeds.Notifications, as: Seed

  doctest Seed

  test "nine groups, Account last, and sixty-eight kinds; a second load changes nothing" do
    _first = Seed.load()
    assert Seed.load() == %{inserted: 0, updated: 0, kept: 77}

    assert [
             %{key: "tasks", label: "Tasks"},
             %{key: "leads", label: "Leads"},
             %{key: "conversations", label: "Conversations"},
             %{key: "meetings", label: "Meetings"},
             %{key: "approvals", label: "Approvals"},
             %{key: "profiles", label: "Profiles", position: 5},
             %{key: "behaviour", label: "Behaviour", position: 6, can_disable: true},
             %{key: "system", label: "System", position: 7},
             # AQ-10B §11.4: Account can be switched off; its locked kinds can't.
             %{key: "account", label: "Account", position: 8, can_disable: true}
           ] = Notifications.groups()

    kinds = Map.new(Notifications.kinds(), &{&1.key, &1})
    assert map_size(kinds) == 68

    # In-app wherever a kind is for an audience at all.
    for {_key, k} <- kinds do
      for channels <- [k.default_channels, k.customer_channels || k.default_channels],
          channels != [],
          do: assert("inapp" in channels)
    end

    # AQ-10B §11.4's Δ rows: staff → customer.
    assert %{default_channels: ~w(inapp push), customer_channels: ~w(inapp push email)} =
             kinds["tasks.assigned"]

    assert %{default_channels: ~w(inapp push), customer_channels: ~w(inapp push email)} =
             kinds["meetings.day_before"]

    assert %{default_channels: [], customer_channels: ~w(inapp push email)} =
             kinds["leads.customer_milestone"]

    assert kinds["approvals.due_soon"].default_channels == ~w(inapp push)
    assert kinds["leads.applied_again"].default_channels == ~w(inapp digest)
    assert kinds["tasks.mentioned"].default_channels == ~w(inapp push extension)
    assert kinds["behaviour.watch_fired"].default_channels == ~w(inapp push extension)
    assert Seed.offered("behaviour.watch_fired", false) == ["email"]
    assert Seed.offered("tasks.assigned", false) == ~w(email extension)

    # The locks (QP10b-4).
    locked = for {key, %{is_locked: true}} <- kinds, do: key
    assert Enum.sort(locked) == ~w(account.extension_connected account.security)
    assert Enum.sort(Seed.locked()) == Enum.sort(locked)

    passing = for {key, %{can_ignore_quiet_hours: true}} <- kinds, do: key

    assert Enum.sort(passing) ==
             ~w(account.digest account.extension_connected account.push_test account.security
                account.weekly_summary account.welcome leads.weekly_report meetings.reminder
                system.delivery_failing system.inbound_failing system.jobs_discarded)
  end

  test "a kind seeded before a change is updated in place; a person's own rows stay" do
    _first = Seed.load()

    Repo.get!(Kind, "meetings.reminder")
    |> Ecto.Changeset.change(default_channels: ["inapp"], can_ignore_quiet_hours: false)
    |> Repo.update!()

    Repo.get!(Data.Notifications.Group, "account")
    |> Ecto.Changeset.change(can_disable: false)
    |> Repo.update!()

    assert Seed.load() == %{inserted: 0, updated: 2, kept: 75}

    assert %{default_channels: ~w(inapp push extension), can_ignore_quiet_hours: true} =
             Repo.get!(Kind, "meetings.reminder")

    assert Repo.get!(Data.Notifications.Group, "account").can_disable
  end

  test "every kind and group has a label for settings and delivery health" do
    for key <- Seed.keys(), do: refute(Seed.label(key) == key)
    assert Seed.label("meetings.day_before") == "Meeting tomorrow"
    assert Seed.label("leads.customer_milestone") == "Your search moved forward"
    assert Seed.label("unknown.kind") == "unknown.kind"
    assert Seed.group_label("profiles") == "Profiles"
  end
end
