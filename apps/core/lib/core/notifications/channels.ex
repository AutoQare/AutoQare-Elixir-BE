defmodule Core.Notifications.Channels do
  @moduledoc """
  Which deliveries a new notification gets, and when (AQ-08 §7.1; AQ-10B
  §11.4): tCart's `put_alert` rule as a **pure** function, tested by a
  table over every kind and chair.

  **The ledger's channels** are `push`, `email` and `extension`. In-app is
  the notification row itself and `digest` is read by the scan, so neither
  is planned here. A channel is planned when:
  - the kind offers it to this audience: among its channels (on by
    default) or its offered ones (off until the person turns them on,
    QP10b-1, §5's ○);
  - the person's switches leave it on: **off at either level is off** —
    the group's switch, then the kind's (no kind row means the kind's
    default). A locked kind ignores both (QP10b-4);
  - the person can have it (AQ-08 §4): push needs a browser turned on in
    their app at write time; the extension a connected device, and staff
    only; email always.

  `only` (a list, the seam's `:only_channels`) narrows the channels, and
  an offered channel named in it counts as asked for: a watch that chose
  email emails (AQ-10 §11.4).

  **When** (`deliver_after`):
  - push and the extension at once; email at once for a customer
    (QP10b-11), for the `meetings`, `account` and `system` groups and a
    locked kind, else 10 minutes on (QP8-10);
  - **snooze** (`snoozed_until`, QP10b-3) holds push, the extension and
    email to its end, `deferred`; a locked kind, `meetings.reminder` and
    the push test pass;
  - **quiet hours hold push and the extension, never email** (QP10b-6),
    to the window's end, `deferred`, unless the kind passes them.

  **Folding** (QP10b-17): a push for a person about the same lead or task
  within 10 minutes of another (`fold: true`, read by the caller) is
  written `skipped · folded`; the bell keeps the row. A locked kind and
  `meetings.reminder` never fold.
  """

  alias Core.Notifications.QuietHours

  @ledger [:push, :email, :extension]
  @email_wait_s 10 * 60
  @email_at_once ~w(meetings account system)
  @passes_snooze ~w(meetings.reminder account.push_test)
  @never_folds ~w(meetings.reminder)

  @typedoc "The kind as planning reads it, for one audience."
  @type kind :: %{
          required(:group) => String.t(),
          required(:channels) => [String.t()],
          required(:can_ignore_quiet_hours) => boolean(),
          optional(:key) => String.t(),
          optional(:offered) => [String.t()],
          optional(:only) => [String.t()] | nil,
          optional(:locked) => boolean(),
          optional(:can_disable) => boolean()
        }

  @typedoc "One planned row; `skip_reason` set when it is written skipped."
  @type planned :: %{
          required(:channel) => atom(),
          required(:deliver_after) => DateTime.t(),
          required(:deferred) => boolean(),
          optional(:skip_reason) => atom() | nil
        }

  @doc "The ledger's channels, in vocabulary order."
  def ledger, do: @ledger

  @doc "How long a staff email waits before it goes, in seconds (QP8-10)."
  def email_wait_s, do: @email_wait_s

  @doc """
  Whether a kind's email goes at once and is never skipped as read
  (AQ-10B §11.4): a customer's, the `meetings`, `account` and `system`
  groups', a locked kind's.

      iex> Core.Notifications.Channels.email_at_once?(%{group: "tasks"}, true)
      true
      iex> Core.Notifications.Channels.email_at_once?(%{group: "tasks"}, false)
      false
      iex> Core.Notifications.Channels.email_at_once?(%{group: "meetings"}, false)
      true
  """
  @spec email_at_once?(map(), boolean()) :: boolean()
  def email_at_once?(kind, customer?) do
    customer? or kind.group in @email_at_once or Map.get(kind, :locked, false)
  end

  @doc """
  The rows to write for one new notification.

  - `kind`: `%{key, group, channels, offered, only, can_ignore_quiet_hours,
    can_disable, locked}` for the recipient's audience;
  - `switches`: `%{group: %{push, email, extension}, kind: map | nil}`
    (a missing group switch means on; `kind: nil` means the kind's
    defaults);
  - `targets`: what the person can have, `%{push, email, extension}`
    (missing means no);
  - `settings`: `%{quiet_hours_start, quiet_hours_end, zone,
    snoozed_until, customer?, fold}`.

  Answers `[%{channel, deliver_after, deferred, skip_reason}]`, in
  vocabulary order.

      iex> Core.Notifications.Channels.plan(
      ...>   %{group: "tasks", channels: ~w(inapp push), can_ignore_quiet_hours: false},
      ...>   %{},
      ...>   %{push: true, email: true},
      ...>   %{quiet_hours_start: nil, quiet_hours_end: nil, zone: "Etc/UTC"},
      ...>   ~U[2026-11-12 10:00:00Z]
      ...> )
      [%{channel: :push, deliver_after: ~U[2026-11-12 10:00:00Z], deferred: false, skip_reason: nil}]
  """
  @spec plan(kind(), map(), map(), map(), DateTime.t()) :: [planned()]
  def plan(kind, switches, targets, settings, %DateTime{} = now) do
    for channel <- @ledger,
        offered_here?(kind, channel),
        on?(kind, switches, channel),
        Map.get(targets, channel, false) do
      kind
      |> timing(channel, settings, now)
      |> fold(kind, settings)
    end
  end

  @doc """
  The kind as one notification plans it (AQ-10 §11.4): `only` (a list of
  channels, or `nil`) narrows its ledger channels — in-app and the digest
  stay — and `passes` (a boolean, or `nil`) stands in for
  `can_ignore_quiet_hours`.

      iex> Core.Notifications.Channels.narrow(
      ...>   %{group: "behaviour", channels: ~w(inapp push extension email), can_ignore_quiet_hours: false},
      ...>   ["push"],
      ...>   true
      ...> )
      %{group: "behaviour", channels: ~w(inapp push extension email), can_ignore_quiet_hours: true, only: ["push"]}
  """
  @spec narrow(kind(), [String.t() | atom()] | nil, boolean() | nil) :: kind()
  def narrow(kind, only, passes) do
    kind
    |> then(
      &if(is_list(only),
        do: Map.put(&1, :only, Enum.map(only, fn c -> to_string(c) end)),
        else: &1
      )
    )
    |> then(&if(is_boolean(passes), do: %{&1 | can_ignore_quiet_hours: passes}, else: &1))
  end

  # Among the kind's channels or its offered ones, and within `only`.
  defp offered_here?(kind, channel) do
    name = Atom.to_string(channel)
    uses? = name in kind.channels or name in Map.get(kind, :offered, [])

    case Map.get(kind, :only) do
      nil -> uses?
      only -> uses? and name in only
    end
  end

  defp on?(kind, switches, channel) do
    cond do
      Map.get(kind, :locked, false) ->
        true

      Map.get(kind, :can_disable, true) and group_off?(switches, channel) ->
        false

      true ->
        case Map.get(switches, :kind) do
          %{} = row -> Map.get(row, channel, true)
          nil -> default_on?(kind, channel)
        end
    end
  end

  defp group_off?(switches, channel) do
    group = Map.get(switches, :group, %{})
    Map.get(group, channel, true) == false
  end

  # No kind row: its channels are on, an offered one only when `only` names it.
  defp default_on?(kind, channel) do
    name = Atom.to_string(channel)
    name in kind.channels or name in (Map.get(kind, :only) || [])
  end

  defp timing(kind, channel, settings, now) do
    at =
      if channel == :email and not email_at_once?(kind, Map.get(settings, :customer?, false)),
        do: DateTime.add(now, @email_wait_s, :second),
        else: now

    hold(kind, channel, at, settings)
  end

  defp fold(%{channel: :push} = planned, kind, settings) do
    folds? =
      Map.get(settings, :fold, false) and not Map.get(kind, :locked, false) and
        Map.get(kind, :key) not in @never_folds

    Map.put(planned, :skip_reason, if(folds?, do: :folded))
  end

  defp fold(planned, _kind, _settings), do: Map.put(planned, :skip_reason, nil)

  @doc """
  When a row due at `at` may go under the person's snooze and quiet hours
  (§11.4): snooze first (push, the extension and email), then quiet hours
  (push and the extension) on what snooze left. Answers `%{channel,
  deliver_after, deferred}`. Also what a changed window or snooze
  re-plans a waiting row by.
  """
  @spec hold(kind(), atom(), DateTime.t(), map()) :: planned()
  def hold(kind, channel, %DateTime{} = at, settings) do
    {at, snoozed?} = snooze(kind, at, settings)
    {at, quiet?} = quiet(kind, channel, at, settings)
    %{channel: channel, deliver_after: at, deferred: snoozed? or quiet?}
  end

  defp snooze(kind, at, settings) do
    with false <- Map.get(kind, :locked, false),
         false <- Map.get(kind, :key) in @passes_snooze,
         %DateTime{} = until <- Map.get(settings, :snoozed_until),
         true <- DateTime.after?(until, at) do
      {until, true}
    else
      _passes -> {at, false}
    end
  end

  defp quiet(_kind, :email, at, _settings), do: {at, false}

  defp quiet(kind, _channel, at, settings) do
    with false <- kind.can_ignore_quiet_hours,
         false <- Map.get(kind, :locked, false),
         %Time{} = from <- settings[:quiet_hours_start],
         %Time{} = until <- settings[:quiet_hours_end],
         %DateTime{} = opens <-
           QuietHours.deliver_after(at, from, until, settings[:zone] || "Etc/UTC") do
      {opens, true}
    else
      _passes_or_off -> {at, false}
    end
  end
end
