defmodule Core.Notifications.ChannelsTest do
  @moduledoc """
  The planning rule (AQ-08 §7.1; AQ-10B §11.4), **as a table over every
  kind, audience and chair**: each of the 68 kinds plans exactly the
  ledger rows its audience's channels give each chair — staff with a
  browser and the extension, staff with neither, a customer with a
  browser, a customer with none — at the right moment; then switches per
  group and kind, offered channels, locks, quiet hours (push and the
  extension only), snooze and folding. Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Core.Notifications.Channels
  alias Data.Seeds.Notifications, as: Seed

  doctest Channels

  @now ~U[2026-11-12 06:00:00Z]
  @kinds Map.new(Seed.kinds(), fn {key, staff, customer} -> {key, {staff, customer || staff}} end)

  @chairs %{
    staff_with_both: {false, %{push: true, email: true, extension: true}},
    staff_bare: {false, %{push: false, email: true, extension: false}},
    customer_with_browser: {true, %{push: true, email: true, extension: false}},
    customer_bare: {true, %{push: false, email: true, extension: false}}
  }

  @no_window %{quiet_hours_start: nil, quiet_hours_end: nil, zone: "Asia/Karachi"}

  defp kind(key, customer? \\ false) do
    {staff, customer} = Map.fetch!(@kinds, key)

    %{
      key: key,
      group: key |> String.split(".") |> hd(),
      channels: if(customer?, do: customer, else: staff),
      offered: Seed.offered(key, customer?),
      only: nil,
      can_ignore_quiet_hours: key in Seed.passing_quiet_hours(),
      locked: key in Seed.locked(),
      can_disable: true
    }
  end

  defp plan(key, switches \\ %{}, chair \\ :staff_with_both, settings \\ @no_window, now \\ @now) do
    {customer?, targets} = Map.fetch!(@chairs, chair)
    settings = Map.put(settings, :customer?, customer?)
    Channels.plan(kind(key, customer?), switches, targets, settings, now)
  end

  defp channels(rows), do: Enum.map(rows, & &1.channel)

  test "every kind × every audience × every chair: exactly its channels the chair can have, at the right moment" do
    for {key, {staff, customer}} <- @kinds,
        {chair, {customer?, targets}} <- @chairs,
        channels = if(customer?, do: customer, else: staff),
        channels != [] do
      expected = for c <- [:push, :email, :extension], "#{c}" in channels, targets[c], do: c
      planned = plan(key, %{}, chair)

      assert channels(planned) == expected, "#{key} for #{chair}"
      refute Enum.any?(planned, & &1.deferred), "#{key} for #{chair} is not held"

      for %{channel: channel, deliver_after: at} <- planned do
        group = key |> String.split(".") |> hd()

        wait =
          if channel == :email and not customer? and group not in ~w(meetings account system) and
               key not in Seed.locked(),
             do: 600,
             else: 0

        assert DateTime.diff(at, @now) == wait, "#{key} #{channel} for #{chair}"
      end
    end
  end

  test "in-app and the digest are never ledger rows" do
    for key <- ~w(tasks.completed tasks.due_soon leads.archived conversations.triage_stale) do
      assert plan(key) == []
    end
  end

  test "a customer's email goes at once (QP10b-11); a staff member's waits ten minutes" do
    assert [%{channel: :email, deliver_after: @now}] =
             plan("tasks.commented", %{}, :customer_bare)

    assert [%{channel: :email, deliver_after: at}] = plan("approvals.overdue", %{}, :staff_bare)
    assert DateTime.diff(at, @now) == 600
  end

  describe "switches" do
    test "a group switch off stops that channel; on (or no row) brings the default back" do
      assert [:email] = "approvals.requested" |> plan(%{group: %{push: false}}) |> channels()
      assert [:push] = "approvals.requested" |> plan(%{group: %{email: false}}) |> channels()

      assert [:push] =
               "conversations.reply_received" |> plan(%{group: %{extension: false}}) |> channels()

      assert [:push, :email] =
               "approvals.requested" |> plan(%{group: %{push: true, email: true}}) |> channels()
    end

    test "a kind switch off stops that channel; off at either level is off" do
      off = %{push: false, email: true, extension: false, digest: true}
      assert [:email] = "approvals.requested" |> plan(%{kind: off}) |> channels()

      on = %{push: true, email: true, extension: false, digest: true}

      assert [:push] =
               "approvals.requested" |> plan(%{group: %{email: false}, kind: on}) |> channels()
    end

    test "an offered channel is off until the person turns it on" do
      assert [:push] = "tasks.assigned" |> plan() |> channels()

      on = %{push: true, email: true, extension: true, digest: true}
      assert [:push, :email, :extension] = "tasks.assigned" |> plan(%{kind: on}) |> channels()
    end

    test "a locked kind ignores both switches" do
      off = %{push: false, email: false, extension: false, digest: false}

      assert [:email] =
               "account.security" |> plan(%{group: off, kind: off}, :staff_bare) |> channels()

      assert [:email] =
               "account.extension_connected" |> plan(%{group: off, kind: off}) |> channels()
    end

    test "`only` narrows the channels, and names an offered one as asked for (a watch's email)" do
      watch = Channels.narrow(kind("behaviour.watch_fired"), ["push", "email"], nil)
      {_c, targets} = @chairs.staff_with_both

      assert [:push, :email] =
               watch |> Channels.plan(%{}, targets, @no_window, @now) |> channels()

      quiet = Channels.narrow(kind("tasks.step_done"), [], nil)
      assert quiet |> Channels.plan(%{}, targets, @no_window, @now) == []
    end
  end

  describe "quiet hours (22:00–08:00 in Karachi)" do
    @window %{
      quiet_hours_start: ~T[22:00:00],
      quiet_hours_end: ~T[08:00:00],
      zone: "Asia/Karachi"
    }
    # 23:00 in Karachi; the window ends at 08:00 there, 03:00 UTC.
    @night ~U[2026-11-12 18:00:00Z]
    @opens ~U[2026-11-13 03:00:00.000000Z]

    test "push and the extension wait for the window's end, marked deferred; email doesn't (QP10b-6)" do
      wait = DateTime.add(@night, 600, :second)

      assert [
               %{channel: :push, deliver_after: @opens, deferred: true},
               %{channel: :email, deliver_after: ^wait, deferred: false}
             ] = plan("approvals.requested", %{}, :staff_with_both, @window, @night)

      assert [
               %{channel: :push, deliver_after: @opens, deferred: true},
               %{channel: :extension, deliver_after: @opens, deferred: true}
             ] = plan("conversations.reply_received", %{}, :staff_with_both, @window, @night)
    end

    test "the kinds that pass, and the locked ones, go now" do
      for key <- Seed.passing_quiet_hours() ++ Seed.locked(),
          row <-
            plan(key, %{}, :staff_with_both, @window, @night) ++
              plan(key, %{}, :customer_with_browser, @window, @night) do
        refute row.deferred, key
      end
    end
  end

  describe "snooze (QP10b-3)" do
    @until ~U[2026-11-12 07:00:00Z]

    test "push, the extension and email are held to its end, deferred" do
      settings = Map.put(@no_window, :snoozed_until, @until)

      assert [
               %{channel: :push, deliver_after: @until, deferred: true},
               %{channel: :extension, deliver_after: @until, deferred: true}
             ] = plan("conversations.reply_received", %{}, :staff_with_both, settings)

      assert [%{channel: :email, deliver_after: @until, deferred: true}] =
               plan("tasks.commented", %{}, :customer_bare, settings)
    end

    test "a locked kind, the meeting reminder and the push test pass" do
      settings = Map.put(@no_window, :snoozed_until, @until)

      for key <- ~w(account.security meetings.reminder account.push_test),
          row <- plan(key, %{}, :staff_with_both, settings) do
        refute row.deferred, key
        assert row.deliver_after == @now
      end
    end

    test "a snooze ending inside quiet hours leaves push held to the window's end" do
      settings =
        @window |> Map.put(:snoozed_until, ~U[2026-11-12 20:00:00Z])

      rows = plan("tasks.assigned", %{}, :staff_with_both, settings, ~U[2026-11-12 10:00:00Z])

      assert [%{channel: :push, deliver_after: ~U[2026-11-13 03:00:00.000000Z], deferred: true}] =
               rows
    end
  end

  describe "folding (QP10b-17)" do
    test "a push within 10 minutes of another about the same subject is written folded" do
      settings = Map.put(@no_window, :fold, true)

      assert [%{channel: :push, skip_reason: :folded}, %{channel: :extension, skip_reason: nil}] =
               plan("conversations.reply_received", %{}, :staff_with_both, settings)
    end

    test "the meeting reminder and a locked kind never fold" do
      settings = Map.put(@no_window, :fold, true)

      assert [%{channel: :push, skip_reason: nil} | _] =
               plan("meetings.reminder", %{}, :staff_with_both, settings)
    end
  end
end
