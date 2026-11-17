defmodule Core.Watches.RuleTest do
  @moduledoc """
  AQ-10 §5, §8, §11.4, pure: which kind feeds which trigger, which
  triggers a subject takes, the cool-down, the expiry, a pause, and quiet
  hours for *comes online* only.
  """

  use ExUnit.Case, async: true

  alias Core.Watches.Rule

  doctest Rule

  @now ~U[2026-11-14 10:00:00Z]
  @kinds Enum.map(Data.Vocabulary.observation_kinds(), &String.to_atom/1)

  defp watch(attrs) do
    Map.merge(
      %{
        trigger: :any_activity,
        paused_at: nil,
        expires_at: nil,
        cooldown_minutes: 120,
        last_fired_at: nil
      },
      Map.new(attrs)
    )
  end

  test "which kind feeds which trigger; last viewed is never online now" do
    takes = fn trigger -> Enum.filter(@kinds, &Rule.takes?(trigger, &1)) end

    assert takes.(:comes_online) == [:seen_online]
    assert takes.(:posts_job) == [:job_posted, :job_reposted]
    assert takes.(:replies) == [:replied]
    assert takes.(:any_activity) == @kinds
  end

  test "a company posts_job and any_activity; a contact comes_online, replies, any_activity" do
    assert Rule.triggers(:company) == [:posts_job, :any_activity]
    assert Rule.triggers(:contact) == [:comes_online, :replies, :any_activity]
  end

  test "due: the kind, not paused, not expired, past the cool-down" do
    assert Rule.due?(watch(trigger: :replies), :replied, @now)
    refute Rule.due?(watch(trigger: :replies), :seen_online, @now)
    refute Rule.due?(watch(paused_at: @now), :replied, @now)
    refute Rule.due?(watch(expires_at: @now), :replied, @now)
    assert Rule.due?(watch(expires_at: DateTime.add(@now, 1, :second)), :replied, @now)

    fired = DateTime.add(@now, -30 * 60, :second)
    refute Rule.due?(watch(last_fired_at: fired), :replied, @now)
    assert Rule.due?(watch(last_fired_at: fired, cooldown_minutes: 30), :replied, @now)
  end

  test "the expiries: none, a week, 30 days; anything else is refused" do
    assert Rule.expires_at(nil, @now) == {:ok, nil}
    assert Rule.expires_at("none", @now) == {:ok, nil}
    assert Rule.expires_at("month", @now) == {:ok, ~U[2026-12-14 10:00:00Z]}
    assert Rule.expires_at(7, @now) == :error
  end

  test "only comes_online passes quiet hours" do
    passing =
      for t <- Data.Vocabulary.watch_triggers(),
          Rule.passes_quiet_hours?(String.to_atom(t)),
          do: t

    assert passing == ["comes_online"]
  end
end
