defmodule Core.Notifications.SettingsTest do
  @moduledoc """
  Notifications › Settings and push on a browser (AQ-08 §8, §11.4): each
  person their own; a switch per group and channel the group uses, none for
  the extension for a customer; P10b: the kinds folded under each group,
  their switches, the locks, snooze; a browser
  turned on in the surface's app, moved when another person signs in
  there; *Send a test* through the pipeline.
  """

  use Core.CoreCase, async: true

  alias Core.Notifications.{Push, Settings}
  alias Data.Notifications.Deliveries

  @now ~U[2026-11-12 06:00:00.000000Z]

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    fiza = member_fixture(team, :member, user_fixture(display_name: "Fiza"))
    customer = customer_fixture(org, [team], login: true)
    tanweer = Data.Accounts.get_user(customer.user_id)
    %{fiza: fiza, fiza_scope: scope_for(fiza), tanweer: tanweer, customer: customer}
  end

  test "the settings: every group the person has kinds in, in order; uses; kinds folded under each; all on",
       c do
    assert {:ok, settings} = Settings.get(c.fiza_scope, :team)

    # AQ-10B §11.4: profiles after approvals; system only for the system admin.
    assert Enum.map(settings.groups, & &1.key) ==
             ~w(tasks leads conversations meetings approvals profiles behaviour account)

    uses = Map.new(settings.groups, &{&1.key, &1.uses})
    assert uses["tasks"] == ~w(push email extension digest)
    assert uses["leads"] == ~w(push extension digest)
    assert uses["conversations"] == ~w(push email extension digest)
    assert uses["meetings"] == ~w(push email extension)
    assert uses["approvals"] == ~w(push email extension)
    assert uses["profiles"] == ~w(push)
    assert uses["behaviour"] == ~w(push email extension digest)
    assert uses["account"] == ~w(push email extension digest)

    assert Enum.all?(settings.groups, &(&1.push and &1.email and &1.extension and &1.digest))
    assert %{key: "account", label: "Account", can_disable: true} = List.last(settings.groups)

    tasks = Enum.find(settings.groups, &(&1.key == "tasks"))

    assert %{
             key: "tasks.assigned",
             label: "Task assigned",
             uses: ~w(push email extension),
             locked: false,
             push: true,
             email: false,
             extension: false,
             digest: nil
           } = hd(tasks.kinds)

    account = Enum.find(settings.groups, &(&1.key == "account"))
    security = Enum.find(account.kinds, &(&1.key == "account.security"))
    assert %{locked: true, email: true, push: nil, uses: ["email"]} = security

    assert settings.quiet_hours == %{from: nil, to: nil}
    assert settings.digest == %{frequency: :daily, at: "08:00"}
    assert settings.snoozed_until == nil
    assert settings.zone == "Asia/Karachi"
    assert settings.has == %{push: false, extension: false}

    push_subscription_fixture(c.fiza, app: :team)
    device_fixture(c.fiza_scope)
    assert {:ok, %{has: %{push: true, extension: true}}} = Settings.get(c.fiza_scope, :team)
    assert {:ok, %{has: %{push: false}}} = Settings.get(c.fiza_scope, :client)
  end

  test "a customer sees customer kinds only, no extension, no empty Digest switch (G8)", c do
    assert {:ok, settings} = Settings.get(customer_scope_for(c.customer), :client)

    assert Enum.map(settings.groups, & &1.key) ==
             ~w(tasks leads conversations meetings approvals profiles account)

    uses = Map.new(settings.groups, &{&1.key, &1.uses})
    assert uses["tasks"] == ~w(push email digest)
    assert uses["leads"] == ~w(push email digest)
    assert uses["meetings"] == ~w(push email)
    assert uses["approvals"] == ~w(push email)
    assert uses["profiles"] == ~w(digest)
    assert uses["account"] == ~w(push email)

    kinds = for g <- settings.groups, k <- g.kinds, do: k.key
    assert "leads.weekly_report" in kinds
    refute "leads.assigned" in kinds
    refute "tasks.mentioned" in kinds
  end

  test "a customer has no extension column and never has the extension", c do
    scope = customer_scope_for(c.customer)
    assert {:ok, settings} = Settings.get(scope, :client)

    refute Enum.any?(settings.groups, &("extension" in &1.uses))
    assert settings.has.extension == false

    # AQ-10: Behaviour is the team's; the portal has no such row, and no switch.
    refute Enum.any?(settings.groups, &(&1.key == "behaviour"))

    assert Settings.put_group(scope, "behaviour", %{"push" => false}, :client, @now) ==
             {:error, :not_found}
  end

  test "a switch turned off and on again; another person's are untouched", c do
    assert {:ok, settings} =
             Settings.put_group(c.fiza_scope, "approvals", %{"email" => false}, :team, @now)

    approvals = Enum.find(settings.groups, &(&1.key == "approvals"))
    assert approvals.email == false and approvals.push == true

    {:ok, settings} =
      Settings.put_group(c.fiza_scope, "approvals", %{"email" => true}, :team, @now)

    assert Enum.find(settings.groups, &(&1.key == "approvals")).email

    {:ok, mine} = Settings.put_group(c.fiza_scope, "tasks", %{push: false}, :team, @now)
    refute Enum.find(mine.groups, &(&1.key == "tasks")).push

    {:ok, theirs} = Settings.get(customer_scope_for(c.customer), :client)
    assert Enum.find(theirs.groups, &(&1.key == "tasks")).push
  end

  test "the refusals: an unknown group, a channel the group doesn't use, the extension for a customer",
       c do
    assert Settings.put_group(c.fiza_scope, "nope", %{"push" => false}, :team, @now) ==
             {:error, :not_found}

    # System is the system admin's: not found for anyone else.
    assert Settings.put_group(c.fiza_scope, "system", %{"push" => false}, :team, @now) ==
             {:error, :not_found}

    assert Settings.put_group(c.fiza_scope, "leads", %{"email" => false}, :team, @now) ==
             {:error, {:invalid, %{"email" => ["This group doesn't use it."]}}}

    assert Settings.put_group(c.fiza_scope, "tasks", %{"push" => "off"}, :team, @now) ==
             {:error, {:invalid, %{"push" => ["must be true or false"]}}}

    assert Settings.put_group(
             customer_scope_for(c.customer),
             "conversations",
             %{"extension" => false},
             :client,
             @now
           ) == {:error, {:invalid, %{"extension" => ["The extension is for the team."]}}}
  end

  describe "kinds (AQ-10B §11.4)" do
    test "a kind's switch off and on; off at the group is off for its kinds; on again restores them",
         c do
      {:ok, settings} =
        Settings.put_kind(c.fiza_scope, "tasks.commented", %{"push" => false}, :team, @now)

      commented = kind(settings, "tasks.commented")
      assert commented.push == false and commented.extension == false

      # An offered channel turned on.
      {:ok, settings} =
        Settings.put_kind(c.fiza_scope, "tasks.assigned", %{"email" => true}, :team, @now)

      assert kind(settings, "tasks.assigned").email

      {:ok, _settings} =
        Settings.put_group(c.fiza_scope, "tasks", %{"push" => false}, :team, @now)

      {:ok, settings} = Settings.put_group(c.fiza_scope, "tasks", %{"push" => true}, :team, @now)
      assert kind(settings, "tasks.commented").push
      assert kind(settings, "tasks.assigned").email
    end

    test "the refusals: locked, unused, the extension for a customer, unknown, not for this audience",
         c do
      assert Settings.put_kind(c.fiza_scope, "account.security", %{"email" => false}, :team, @now) ==
               {:error, {:invalid, %{"kind" => ["These can't be turned off."]}}}

      assert Settings.put_kind(c.fiza_scope, "tasks.completed", %{"push" => false}, :team, @now) ==
               {:error, {:invalid, %{"push" => ["This kind doesn't use it."]}}}

      assert Settings.put_kind(c.fiza_scope, "nope.kind", %{"push" => false}, :team, @now) ==
               {:error, :not_found}

      assert Settings.put_kind(
               c.fiza_scope,
               "leads.weekly_report",
               %{"email" => false},
               :team,
               @now
             ) == {:error, :not_found}

      customer = customer_scope_for(c.customer)

      assert Settings.put_kind(customer, "tasks.assigned", %{"extension" => false}, :client, @now) ==
               {:error, {:invalid, %{"extension" => ["The extension is for the team."]}}}

      assert Settings.put_kind(customer, "leads.assigned", %{"push" => false}, :client, @now) ==
               {:error, :not_found}
    end
  end

  describe "snooze (QP10b-3)" do
    test "an hour, until tomorrow 08:00, until Monday 08:00 in the person's zone; null ends it",
         c do
      # Thursday 12 Nov 11:00 in Karachi.
      {:ok, s} = Settings.put_snooze(c.fiza_scope, %{"for" => "hour"}, :team, @now)
      assert s.snoozed_until == DateTime.add(@now, 3600, :second)

      {:ok, s} = Settings.put_snooze(c.fiza_scope, %{"for" => "tomorrow"}, :team, @now)
      assert s.snoozed_until == ~U[2026-11-13 03:00:00.000000Z]

      {:ok, s} = Settings.put_snooze(c.fiza_scope, %{"for" => "monday"}, :team, @now)
      assert s.snoozed_until == ~U[2026-11-16 03:00:00.000000Z]

      {:ok, s} = Settings.put_snooze(c.fiza_scope, %{"for" => nil}, :team, @now)
      assert s.snoozed_until == nil

      assert Settings.put_snooze(c.fiza_scope, %{"for" => "week"}, :team, @now) ==
               {:error, {:invalid, %{"for" => ["is hour, tomorrow, monday or null"]}}}
    end

    test "a snooze holds what is waiting, and ending it lets it go", c do
      push_subscription_fixture(c.fiza)

      {:ok, n} =
        Core.Notifications.ensure(
          Data.Scope.system(%{id: c.fiza_scope.organisation.id}),
          %{
            user_id: c.fiza.id,
            notification_kind_key: "tasks.assigned",
            title: "Hira gave you a task",
            dedupe_key: "snooze-test"
          },
          @now
        )

      assert [%{deferred: false}] = Deliveries.for_notification(n.id)

      {:ok, _s} = Settings.put_snooze(c.fiza_scope, %{"for" => "hour"}, :team, @now)
      assert [%{deferred: true, deliver_after: until}] = Deliveries.for_notification(n.id)
      assert until == DateTime.add(@now, 3600, :second)

      {:ok, _s} = Settings.put_snooze(c.fiza_scope, %{"for" => nil}, :team, @now)
      assert [%{deferred: false, deliver_after: @now}] = Deliveries.for_notification(n.id)
    end
  end

  defp kind(settings, key) do
    settings.groups |> Enum.flat_map(& &1.kinds) |> Enum.find(&(&1.key == key))
  end

  describe "push on a browser" do
    @keys %{"p256dh" => "BPkey", "auth" => "authsecret"}

    test "turned on in the surface's app, newest first; a known endpoint moves; removed by endpoint",
         c do
      {:ok, page} =
        Push.subscribe(
          c.fiza_scope,
          :team,
          %{"endpoint" => "https://fcm.example/a", "keys" => @keys, "app" => "client"},
          @now
        )

      assert [%{app: :team, endpoint: "https://fcm.example/a", inserted_at: _}] = page.devices
      assert page.public_key =~ ~r/^B/

      # The same browser, signed in as the customer on the portal: it moves to them.
      tanweer = customer_scope_for(c.customer)

      {:ok, theirs} =
        Push.subscribe(
          tanweer,
          :client,
          %{"endpoint" => "https://fcm.example/a", "keys" => @keys},
          @now
        )

      assert [%{app: :client}] = theirs.devices
      assert {:ok, %{devices: []}} = Push.page(c.fiza_scope)

      # Removing another's endpoint is no error and removes nothing.
      assert {:ok, %{devices: []}} =
               Push.remove(c.fiza_scope, %{"endpoint" => "https://fcm.example/a"})

      assert {:ok, %{devices: [_still]}} = Push.page(tanweer)

      assert {:ok, %{devices: []}} =
               Push.remove(tanweer, %{"endpoint" => "https://fcm.example/a"})
    end

    test "422 on endpoint for a missing key or an endpoint not https://", c do
      lost =
        {:error,
         {:invalid, %{"endpoint" => ["This browser's subscription didn't come through."]}}}

      assert Push.subscribe(
               c.fiza_scope,
               :team,
               %{"endpoint" => "http://x.example/a", "keys" => @keys},
               @now
             ) == lost

      assert Push.subscribe(
               c.fiza_scope,
               :team,
               %{"endpoint" => "https://x.example/a", "keys" => %{"auth" => "a"}},
               @now
             ) == lost

      assert Push.subscribe(c.fiza_scope, :team, %{"keys" => @keys}, @now) == lost
    end

    test "Send a test: account.push_test through the pipeline, each press its own", c do
      push_subscription_fixture(c.fiza)

      assert :ok = Push.test(c.fiza_scope, @now)
      assert :ok = Push.test(c.fiza_scope, DateTime.add(@now, 1, :second))

      tests =
        for n <- Repo.all(Data.Notifications.Notification),
            n.notification_kind_key == "account.push_test",
            do: n

      assert [
               %{
                 title: "Push works. AutoQare can reach this browser.",
                 link_path: "/notifications"
               } = n,
               _two
             ] = tests

      assert n.dedupe_key =~ "push_test:#{c.fiza.id}:"
      assert [%{channel: :push, deliver_after: _}] = Deliveries.for_notification(n.id)
    end
  end
end
