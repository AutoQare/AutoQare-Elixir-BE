defmodule Core.Notifications.Settings do
  @moduledoc """
  Notifications › Settings (AQ-08 §8; AQ-10B §6, §11.4, QP10b-3, QP10b-4),
  **each person their own**: every read and write is bound to the scope's
  user.

  - **The groups:** a row per group the person's audience has kinds in, in
    their order (`system` only for the system admin; a customer sees only
    customer kinds and never the extension). Each carries a switch per
    channel its kinds use (`uses`, within `push · email · extension ·
    digest`), on until turned off, and **its kinds folded under it**:
    `kinds: [{key, label, uses, locked, push, email, extension, digest}]`,
    a switch only for the channels the kind uses (`null` otherwise), its
    offered channels off until turned on. **Off at either level is off.**
    Turning a group's switch back on returns its kinds' rows for that
    channel to their defaults.
  - **Locked** kinds (security) can't be switched off; Account is a group
    like the others since P10b. In-app is always on.
  - **Snooze** (*Pause notifications*): `snoozed_until`, set by `PUT
    /notifications/settings/snooze {for}`; quiet hours and the digest's
    frequency and time (`digest: {frequency, at}`) are saved through P1's
    `PUT /me/settings`; this answer carries them, the person's zone and
    what they have (`has.push`, `has.extension`).
  """

  alias Core.Notifications.{Deliveries, Snooze}
  alias Data.Accounts
  alias Data.Devices
  alias Data.Notifications, as: Store
  alias Data.Notifications.{Kind, KindPreference, KindPreferences, Preference, Preferences}
  alias Data.Notifications.PushSubscriptions
  alias Data.Scope
  alias Data.Seeds.Notifications, as: Seed

  @channels ~w(push email extension digest)
  @not_used "This group doesn't use it."
  @kind_not_used "This kind doesn't use it."
  @locked "These can't be turned off."
  @team_only "The extension is for the team."

  @doc "`GET /notifications/settings` from `app` (`:team` or `:client`): **settings**."
  @spec get(Scope.t(), atom()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, app) do
    with {:ok, who} <- me(scope), do: {:ok, view(scope, who, app)}
  end

  @doc """
  `PUT /notifications/settings/groups/:key` with `{push?, email?,
  extension?, digest?}` (booleans): the group's switches, then the
  settings. 404 for an unknown group or one not for this person; 422 on a
  channel the group doesn't use, on `extension` for a customer, and on a
  value that isn't true or false. A switch turned on returns the group's
  kinds to their defaults for that channel.
  """
  @spec put_group(Scope.t(), String.t(), map(), atom(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def put_group(%Scope{} = scope, key, params, app, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, who} <- me(scope),
         %{} = group <- Store.get_group(key) || {:error, :not_found},
         kinds = kinds_for(scope, who, group.key),
         :ok <- if(kinds == [], do: {:error, :not_found}, else: :ok),
         :ok <- can_disable(group),
         {:ok, given} <- switches(params, group_uses(kinds), who.customer?, @not_used) do
      current = who.user.id |> Preferences.get(group.key) |> Preference.switches()
      {:ok, _row} = Preferences.put(who.user.id, group.key, Map.merge(current, given), now)

      for {channel, true} <- given do
        defaults = Map.new(kinds, &{&1.kind.key, default_on?(&1, channel)})
        :ok = KindPreferences.reset_channel(who.user.id, group.key, channel, defaults, now)
      end

      {:ok, view(scope, who, app)}
    end
  end

  defp can_disable(%{can_disable: true}), do: :ok
  defp can_disable(_group), do: {:error, {:invalid, %{"group" => [@locked]}}}

  @doc """
  `PUT /notifications/settings/kinds/:key` with `{push?, email?,
  extension?, digest?}`: the kind's switches, then the settings. 404 for an
  unknown kind or one not for this audience; 422 for a locked kind (on
  `kind`), a channel it doesn't use, `extension` for a customer, a value
  that isn't true or false.
  """
  @spec put_kind(Scope.t(), String.t(), map(), atom(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def put_kind(%Scope{} = scope, key, params, app, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, who} <- me(scope),
         %Kind{} = kind <- Store.get_kind(key) || {:error, :not_found},
         %{} = k <-
           Enum.find(kinds_for(scope, who, kind.notification_group_key), &(&1.kind.key == key)) ||
             {:error, :not_found},
         :ok <- if(kind.is_locked, do: {:error, {:invalid, %{"kind" => [@locked]}}}, else: :ok),
         {:ok, given} <- switches(params, k.uses, who.customer?, @kind_not_used) do
      current = effective(k, KindPreferences.get(who.user.id, key))
      {:ok, _row} = KindPreferences.put(who.user.id, key, Map.merge(current, given), now)
      {:ok, view(scope, who, app)}
    end
  end

  @doc """
  `PUT /notifications/settings/snooze` with `{for: "hour" | "tomorrow" |
  "monday" | null}`: *Pause notifications* for an hour, until tomorrow
  08:00 or until Monday 08:00 in the person's zone; `null` ends it. The
  person's waiting rows are re-planned at once. Answers the settings; 422
  on `for` for anything else.
  """
  @spec put_snooze(Scope.t(), map(), atom(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def put_snooze(%Scope{} = scope, params, app, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, who} <- me(scope),
         {:ok, until} <- Snooze.until(Map.get(params, "for"), now, who.zone),
         {:ok, _settings} <- Accounts.put_settings(who.user.id, %{snoozed_until: until}) do
      _moved = Deliveries.replan(who.user.id, now)
      {:ok, who} = me(scope)
      {:ok, view(scope, who, app)}
    end
  end

  defp switches(params, uses, customer?, not_used) do
    {given, errors} =
      Enum.reduce(@channels, {%{}, %{}}, fn channel, {given, errors} ->
        case Map.fetch(params, channel) do
          :error -> {given, errors}
          {:ok, value} -> check(channel, value, uses, customer?, not_used, {given, errors})
        end
      end)

    if errors == %{}, do: {:ok, given}, else: {:error, {:invalid, errors}}
  end

  defp check("extension", _value, _uses, true, _not_used, {given, errors}),
    do: {given, Map.put(errors, "extension", [@team_only])}

  defp check(channel, value, uses, _customer?, not_used, {given, errors}) do
    cond do
      not is_boolean(value) -> {given, Map.put(errors, channel, ["must be true or false"])}
      channel not in uses -> {given, Map.put(errors, channel, [not_used])}
      true -> {Map.put(given, String.to_existing_atom(channel), value), errors}
    end
  end

  # ── The answer ──────────────────────────────────────────────────────────────

  defp view(scope, who, app) do
    user_id = who.user.id
    prefs = Preferences.for_user(user_id)
    kind_prefs = KindPreferences.for_user(user_id)
    all = all_kinds(scope, who)

    groups =
      for g <- Store.groups(), kinds = Map.get(all, g.key, []), kinds != [] do
        switches = Preference.switches(prefs[g.key])

        %{
          key: g.key,
          label: g.label,
          can_disable: g.can_disable,
          uses: group_uses(kinds),
          push: switches.push,
          email: switches.email,
          extension: switches.extension,
          digest: switches.digest,
          kinds: Enum.map(kinds, &kind_view(&1, kind_prefs[&1.kind.key]))
        }
      end

    s = who.settings

    %{
      groups: groups,
      quiet_hours: %{from: hh_mm(s.quiet_hours_start), to: hh_mm(s.quiet_hours_end)},
      snoozed_until: snoozed(s.snoozed_until),
      digest: %{frequency: s.digest_frequency, at: hh_mm(s.digest_time)},
      zone: who.zone,
      has: %{
        push: PushSubscriptions.any?(user_id, app),
        extension: not who.customer? and Devices.connected?(user_id)
      }
    }
  end

  defp kind_view(k, row) do
    on = effective(k, row)

    Map.merge(
      %{key: k.kind.key, label: Seed.label(k.kind.key), uses: k.uses, locked: k.kind.is_locked},
      Map.new(@channels, fn c ->
        atom = String.to_existing_atom(c)
        {atom, if(c in k.uses, do: k.kind.is_locked or Map.fetch!(on, atom))}
      end)
    )
  end

  # The kind's switches as they stand: its row, else on for its channels
  # and off for the offered ones.
  defp effective(k, nil),
    do: Map.new(@channels, &{String.to_existing_atom(&1), default_on?(k, &1)})

  defp effective(_k, %KindPreference{} = row), do: KindPreference.switches(row)

  defp default_on?(k, channel), do: to_string(channel) in k.channels

  # `%{group => [%{kind, channels, uses}]}` for this person's audience, in
  # the seed's order: kinds not for them dropped, `system` only for the
  # system admin, never the extension for a customer.
  defp all_kinds(scope, who) do
    order = Seed.keys() |> Enum.with_index() |> Map.new()

    Store.kinds_with_groups()
    |> Enum.sort_by(&Map.get(order, &1.key, 999))
    |> Enum.flat_map(&for_audience(&1, scope, who))
    |> Enum.group_by(& &1.kind.notification_group_key)
  end

  defp kinds_for(scope, who, group_key), do: Map.get(all_kinds(scope, who), group_key, [])

  defp for_audience(kind, scope, who) do
    channels = Kind.channels(kind, who.customer?)
    allowed = if who.customer?, do: @channels -- ["extension"], else: @channels

    uses =
      Enum.filter(allowed, &(&1 in channels or &1 in Seed.offered(kind.key, who.customer?)))

    cond do
      channels == [] -> []
      kind.notification_group_key == "system" and not Scope.admin?(scope) -> []
      true -> [%{kind: kind, channels: channels, uses: uses}]
    end
  end

  defp group_uses(kinds) do
    used = Enum.flat_map(kinds, & &1.uses)
    Enum.filter(@channels, &(&1 in used))
  end

  @doc """
  The channels each group's kinds use for an audience, within `push ·
  email · extension · digest` and in that order (offered ones included),
  without `extension` for a customer: `%{group => [channel]}`.
  """
  @spec uses_by_group(boolean()) :: %{String.t() => [String.t()]}
  def uses_by_group(customer?) do
    allowed = if customer?, do: @channels -- ["extension"], else: @channels

    Store.kinds()
    |> Enum.group_by(& &1.notification_group_key, fn k ->
      Kind.channels(k, customer?) ++
        if(Kind.channels(k, customer?) == [], do: [], else: Seed.offered(k.key, customer?))
    end)
    |> Map.new(fn {group, lists} ->
      used = List.flatten(lists)
      {group, Enum.filter(allowed, &(&1 in used))}
    end)
    |> Map.reject(fn {_group, uses} -> uses == [] end)
  end

  defp snoozed(nil), do: nil
  defp snoozed(%DateTime{} = at), do: at

  defp hh_mm(nil), do: nil
  defp hh_mm(%Time{} = t), do: t |> Time.to_iso8601() |> binary_part(0, 5)

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp me(scope) do
    with id when is_binary(id) <- Scope.user_id(scope),
         %{} = who <- Store.recipient(id) do
      {:ok, who}
    else
      _nobody -> {:error, :not_found}
    end
  end
end
