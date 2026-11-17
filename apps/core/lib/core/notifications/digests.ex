defmodule Core.Notifications.Digests do
  @moduledoc """
  The digest scan (AQ-08 §7.4, QP8-12; AQ-10B QP10b-12), run every five
  minutes by `Core.Workers.DigestScan` and by the dev sweeps.
  **Idempotent**: a person is due once their digest time has passed today
  in their zone (for a weekly digest, on Monday), and the digest is
  ensured as `account.digest` keyed by that local date, so a second scan
  that day finds it there. `off` writes none.

  It says the person's unread notifications of the kinds their digest
  collects — the kind has the digest among its channels for their
  audience (staff or customer), or offered and turned on, and neither the
  group's nor the kind's digest switch is off — since their last digest
  (the first covers a day, or a week); nothing to say means no digest. It
  reaches the person through the ordinary pipeline: the bell, and email
  at once (the `account` group, which passes quiet hours and is never
  skipped as read).
  """

  alias Core.Notifications
  alias Core.Notifications.Digest
  alias Data.Notifications, as: Store
  alias Data.Notifications.{Kind, KindPreferences, Preferences}
  alias Data.Scope
  alias Data.Seeds.Notifications, as: Seed

  @doc "Runs the scan at `now`. Answers how many digests it wrote."
  @spec scan(DateTime.t()) :: non_neg_integer()
  def scan(%DateTime{} = now) do
    groups = Enum.map(Store.groups(), &%{key: &1.key, label: &1.label})
    kinds = Store.kinds()

    Store.digest_candidates_for_system()
    |> Enum.count(&(write(&1, groups, kinds, now) == :written))
  end

  defp write(%{user_id: user_id} = person, groups, kinds, now) do
    with {:due, date} <-
           Digest.due(person.digest_time, person.zone, now, person.digest_frequency),
         key = Digest.key(user_id, date),
         false <- Store.exists?(user_id, key),
         rows =
           Store.unread_for_digest(
             user_id,
             since(user_id, person.digest_frequency, now),
             collected(user_id, person.customer?, kinds)
           ),
         %{} = digest <- Digest.compose(rows, groups) do
      organisation_id = List.last(rows).organisation_id

      {:ok, row} =
        Notifications.ensure(
          Scope.system(%{id: organisation_id}),
          %{
            organisation_id: organisation_id,
            user_id: user_id,
            notification_kind_key: "account.digest",
            title: digest.title,
            body: digest.body,
            link_path: "/notifications?unread=1",
            dedupe_key: key
          },
          now
        )

      if row.is_new, do: Notifications.created([row])
      :written
    else
      _not_due_written_or_nothing -> :none
    end
  end

  # Since the person's latest digest, else the last day (or week).
  defp since(user_id, frequency, now),
    do:
      Store.latest_at(user_id, "account.digest") ||
        DateTime.add(now, -Digest.window_s(frequency), :second)

  @doc """
  The kinds a person's digest collects (`kinds` as stored): for their
  audience, with the digest among the kind's channels (or offered and
  turned on), and neither the group's nor the kind's digest switch off.
  """
  @spec collected(binary(), boolean(), [Kind.t()]) :: [String.t()]
  def collected(user_id, customer?, kinds) do
    off_groups = Preferences.off_groups(user_id, :digest)
    off_kinds = KindPreferences.off_kinds(user_id, :digest)
    on_kinds = KindPreferences.on_kinds(user_id, :digest)

    for k <- kinds,
        Kind.channels(k, customer?) != [],
        "digest" in Kind.channels(k, customer?) or
          ("digest" in Seed.offered(k.key, customer?) and k.key in on_kinds),
        k.notification_group_key not in off_groups,
        k.key not in off_kinds,
        do: k.key
  end
end
