defmodule Core.Watches.Rule do
  @moduledoc """
  When a watch fires (AQ-10 §5, §8, §11.4, QP10-8…11), **pure**.

  - **Which kind feeds which trigger:** `comes_online` ← `seen_online`
    only (*last viewed* reports the past, never "now"); `posts_job` ←
    `job_posted` · `job_reposted`; `replies` ← `replied`; `any_activity`
    ← every kind.
  - **Which triggers a subject takes:** a company `posts_job` ·
    `any_activity`; a contact `comes_online` · `replies` · `any_activity`.
  - **Due:** the trigger takes the kind, the watch isn't paused, isn't
    expired, and is past its cool-down since it last fired.
  - **Quiet hours:** only `comes_online` passes them (QP10-10).
  """

  @takes %{
    comes_online: [:seen_online],
    posts_job: [:job_posted, :job_reposted],
    replies: [:replied]
  }
  @subject_triggers %{
    company: [:posts_job, :any_activity],
    contact: [:comes_online, :replies, :any_activity]
  }
  @expiries %{"week" => 7, "month" => 30}

  @doc """
  Whether `trigger` takes an observation of `kind`.

      iex> Core.Watches.Rule.takes?(:comes_online, :last_active_reported)
      false
      iex> Core.Watches.Rule.takes?(:any_activity, :last_active_reported)
      true
  """
  @spec takes?(atom(), atom()) :: boolean()
  def takes?(:any_activity, _kind), do: true
  def takes?(trigger, kind), do: kind in Map.get(@takes, trigger, [])

  @doc "The triggers a subject kind takes (`:company`, `:contact`), in vocabulary order."
  @spec triggers(:company | :contact) :: [atom()]
  def triggers(kind), do: Map.fetch!(@subject_triggers, kind)

  @doc """
  Whether the watch fires for an observation of `kind` at `now`.

      iex> watch = %{trigger: :posts_job, paused_at: nil, expires_at: nil, cooldown_minutes: 120,
      ...>   last_fired_at: ~U[2026-11-14 09:00:00Z]}
      iex> Core.Watches.Rule.due?(watch, :job_posted, ~U[2026-11-14 10:00:00Z])
      false
      iex> Core.Watches.Rule.due?(watch, :job_posted, ~U[2026-11-14 11:00:00Z])
      true
  """
  @spec due?(map(), atom(), DateTime.t()) :: boolean()
  def due?(watch, kind, %DateTime{} = now) do
    takes?(watch.trigger, kind) and is_nil(watch.paused_at) and not expired?(watch, now) and
      cooled?(watch, now)
  end

  @doc "Whether the watch's expiry has passed at `now`."
  @spec expired?(map(), DateTime.t()) :: boolean()
  def expired?(%{expires_at: nil}, _now), do: false
  def expired?(%{expires_at: at}, now), do: not DateTime.after?(at, now)

  defp cooled?(%{last_fired_at: nil}, _now), do: true

  defp cooled?(%{last_fired_at: at, cooldown_minutes: minutes}, now),
    do: not DateTime.before?(now, DateTime.add(at, minutes * 60, :second))

  @doc """
  When a watch made at `now` expires: `nil` for none, a week or 30 days on.

      iex> Core.Watches.Rule.expires_at("week", ~U[2026-11-14 10:00:00Z])
      {:ok, ~U[2026-11-21 10:00:00Z]}
      iex> Core.Watches.Rule.expires_at("year", ~U[2026-11-14 10:00:00Z])
      :error
  """
  @spec expires_at(term(), DateTime.t()) :: {:ok, DateTime.t() | nil} | :error
  def expires_at(choice, _now) when choice in [nil, "none"], do: {:ok, nil}

  def expires_at(choice, now) when is_map_key(@expiries, choice),
    do: {:ok, DateTime.add(now, Map.fetch!(@expiries, choice) * 86_400, :second)}

  def expires_at(_choice, _now), do: :error

  @doc "Whether a watch's notification passes quiet hours (QP10-10): *comes online* only."
  @spec passes_quiet_hours?(atom()) :: boolean()
  def passes_quiet_hours?(trigger), do: trigger == :comes_online
end
