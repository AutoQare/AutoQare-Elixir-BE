defmodule Core.Notifications.Deliveries do
  @moduledoc """
  The seam's second half (AQ-08 §7.1, QP8-1): **a new notification's
  deliveries planned in its own transaction**, as tCart's `put_alert` does.
  `Core.Notifications.ensure/3` calls `plan/3` when the row is new; nothing
  else writes the ledger's rows.

  It reads what the pure rule needs — the kind for the recipient's
  audience (P10b: staff or customer channels, the offered ones, locked),
  the person's switches for its group and for the kind, what they can have
  (a browser turned on in their app, a connected device), their quiet
  hours, snooze and zone, and whether a push about the same lead or task
  went in the last 10 minutes (folding) — hands it to
  `Core.Notifications.Channels.plan/5`, writes one row per channel, and
  **when a push or email row is due now enqueues the delivery worker by
  its name in config** (`config :core, :delivery_worker`), unique for 2
  seconds. The job is inserted in the same transaction, so a notification
  that rolls back sends nothing.

  `replan/2` is the other half of a changed window or snooze (§11.4): `PUT
  /me/settings` and `PUT /notifications/settings/snooze` move the person's
  waiting rows to the new window's or snooze's end, or let them go now.
  """

  alias Core.Notifications.Channels
  alias Data.Devices
  alias Data.Notifications
  alias Data.Notifications.{Deliveries, Kind, KindPreferences, Notification, Preferences}
  alias Data.Notifications.KindPreference
  alias Data.Notifications.PushSubscriptions
  alias Data.Seeds.Notifications, as: Seed

  require Logger

  @fold_s 10 * 60

  @doc """
  Plans and writes a new notification's rows. `opts` (a map): `ics` (a
  meeting's calendar file) rides on its email row; `only_channels`
  narrows the kind's channels (the bell stays); `passes_quiet_hours`
  stands in for the kind's own (AQ-10 §11.4). Answers the rows written
  (none for a kind whose channels are in-app and the digest alone).
  """
  @spec plan(Notification.t(), map(), DateTime.t()) :: list()
  def plan(%Notification{} = n, opts, %DateTime{} = now) when is_map(opts) do
    with %Kind{} = kind <- Notifications.get_kind(n.notification_kind_key),
         %{} = who <- Notifications.recipient(n.user_id),
         planning = kind_for_plan(kind, who.customer?),
         true <- beyond_the_bell?(planning) do
      planned =
        Channels.plan(
          Channels.narrow(planning, opts[:only_channels], opts[:passes_quiet_hours]),
          switches(n.user_id, kind),
          targets(who),
          settings(who)
          |> Map.put(:fold, fold?(n, now)),
          now
        )

      rows = Deliveries.insert_planned(n, planned, opts[:ics], now)
      if Enum.any?(rows, &due_now?(&1, now)), do: deliver_soon()
      rows
    else
      _nothing_to_plan -> []
    end
  end

  @doc """
  Re-plans the person's waiting rows after their quiet hours or snooze
  changed (AQ-08 §11.4; AQ-10B §11.4): each is due when it would have been
  with neither, then held again only if the new window or snooze holds it.
  Answers how many it looked at.
  """
  @spec replan(binary(), DateTime.t()) :: non_neg_integer()
  def replan(user_id, %DateTime{} = now) do
    case {Deliveries.pending(user_id), Notifications.recipient(user_id)} do
      {[], _who} ->
        0

      {_rows, nil} ->
        0

      {rows, who} ->
        settings = settings(who)

        moved =
          for row <- rows do
            kind = kind_for_plan(row.notification.notification_kind, who.customer?)
            plan = Channels.hold(kind, row.channel, unheld_at(kind, row, who, now), settings)
            :ok = Deliveries.replan(row, plan.deliver_after, plan.deferred, now)
            Map.merge(row, plan)
          end

        if Enum.any?(moved, &due_now?(&1, now)), do: deliver_soon()
        length(moved)
    end
  end

  @doc "The P8 name for `replan/2`: a changed quiet-hours window."
  @spec replan_held(binary(), DateTime.t()) :: non_neg_integer()
  def replan_held(user_id, %DateTime{} = now), do: replan(user_id, now)

  # When the row would go with no quiet hours and no snooze: a held email
  # keeps its wait from when it was written; a row not held keeps its own
  # time (a retry's included), never earlier than now.
  defp unheld_at(kind, %{deferred: true, channel: :email, inserted_at: written}, who, now) do
    due =
      if Channels.email_at_once?(kind, who.customer?),
        do: written,
        else: DateTime.add(written, Channels.email_wait_s(), :second)

    later(due, now)
  end

  defp unheld_at(_kind, %{deferred: true}, _who, now), do: now
  defp unheld_at(_kind, %{deliver_after: at}, _who, now), do: later(at, now)

  defp later(a, b), do: if(DateTime.after?(a, b), do: a, else: b)

  @doc """
  Enqueues the delivery worker now, by its configured name (`config :core,
  :delivery_worker`; `core` never names a `notifire` module), unique for 2
  seconds so a burst of notifications is one sweep.
  """
  @spec deliver_soon() :: :ok
  def deliver_soon do
    case Application.get_env(:core, :delivery_worker) do
      nil ->
        :ok

      worker ->
        %{}
        |> Oban.Job.new(worker: worker, queue: :notifications, unique: [period: 2])
        |> Oban.insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> Logger.error("could not enqueue delivery: #{inspect(reason)}")
        end

        :ok
    end
  end

  # ── Inputs ──────────────────────────────────────────────────────────────────

  defp beyond_the_bell?(kind),
    do: Enum.any?(kind.channels ++ kind.offered, &(&1 in ~w(push email extension)))

  @doc """
  The kind as planning reads it for an audience (`customer?`): its
  channels and offered ones for that audience, its group, whether it
  passes quiet hours, is locked, and can be switched off.
  """
  @spec kind_for_plan(Kind.t(), boolean()) :: Channels.kind()
  def kind_for_plan(%Kind{} = kind, customer? \\ false) do
    %{
      key: kind.key,
      group: kind.notification_group_key,
      channels: Kind.channels(kind, customer?),
      offered: Seed.offered(kind.key, customer?),
      only: nil,
      can_ignore_quiet_hours: kind.can_ignore_quiet_hours,
      locked: kind.is_locked,
      can_disable: kind.notification_group.can_disable
    }
  end

  defp switches(user_id, kind) do
    %{
      group: Preferences.switches(user_id, kind.notification_group_key),
      kind:
        case KindPreferences.get(user_id, kind.key) do
          nil -> nil
          row -> KindPreference.switches(row)
        end
    }
  end

  # What the person can have (§4, QP8-7): push needs a browser turned on in
  # their app; the extension a connected device, staff only; email always.
  defp targets(who) do
    %{
      push: PushSubscriptions.any?(who.user.id, who.app),
      email: true,
      extension: not who.customer? and Devices.connected?(who.user.id)
    }
  end

  @doc false
  def settings(who) do
    %{
      quiet_hours_start: who.settings.quiet_hours_start,
      quiet_hours_end: who.settings.quiet_hours_end,
      snoozed_until: who.settings.snoozed_until,
      zone: who.zone,
      customer?: who.customer?
    }
  end

  defp fold?(%Notification{} = n, now) do
    Deliveries.recent_push?(n.user_id, n.lead_id, n.task_id, DateTime.add(now, -@fold_s, :second))
  end

  defp due_now?(%{state: :skipped}, _now), do: false

  defp due_now?(%{channel: channel, deliver_after: at}, now),
    do: channel in [:push, :email] and not DateTime.after?(at, now)
end
