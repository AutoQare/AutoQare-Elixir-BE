defmodule Core.Dashboards.Targets do
  @moduledoc """
  A member's daily target (AQ-11 §5, QP11-1, QP11-2; Q30), **pure**. The
  count it is held against is their applications that day.

  - **In a team** (the team table, `GET /teams/:id/members`): their own
    override in that team (`team_members.daily_target`) if set, else the
    sum of the daily targets of the live profiles they own whose customer
    that team serves, else none.
  - **Their own** (*My numbers*): the overrides of the teams they are in,
    plus the targets of the profiles they own that no overridden team
    serves; none when there is neither. In one team — every case today —
    that is the override if set, else the sum of their profiles'.
  - **Working days only:** on a day off the organisation's
    `working_days` there is no target (`nil`); applications still count.

  A profile row is `%{profile_id, daily_target, team_ids}`; a membership
  `%{team_id, daily_target}`.
  """

  alias Core.Dashboards.Windows

  @doc """
  The target in `team_id` from an override and the owned profiles.

      iex> Core.Dashboards.Targets.in_team(nil, [%{profile_id: "p", daily_target: 35, team_ids: ["t"]}], "t")
      35
      iex> Core.Dashboards.Targets.in_team(20, [%{profile_id: "p", daily_target: 35, team_ids: ["t"]}], "t")
      20
      iex> Core.Dashboards.Targets.in_team(nil, [], "t")
      nil
  """
  @spec in_team(non_neg_integer() | nil, [map()], binary()) :: non_neg_integer() | nil
  def in_team(override, _profiles, _team_id) when is_integer(override), do: override

  def in_team(nil, profiles, team_id),
    do: profiles |> Enum.filter(&(team_id in &1.team_ids)) |> sum()

  @doc """
  A person's own target from their memberships and owned profiles.

      iex> Core.Dashboards.Targets.person([%{team_id: "t", daily_target: nil}],
      ...>   [%{profile_id: "a", daily_target: 20, team_ids: ["t"]}, %{profile_id: "b", daily_target: 15, team_ids: ["t"]}])
      35
      iex> Core.Dashboards.Targets.person([%{team_id: "t", daily_target: 30}],
      ...>   [%{profile_id: "a", daily_target: 20, team_ids: ["t"]}])
      30
  """
  @spec person([map()], [map()]) :: non_neg_integer() | nil
  def person(memberships, profiles) do
    overridden = for %{daily_target: n} = m when is_integer(n) <- memberships, do: m
    covered = MapSet.new(overridden, & &1.team_id)
    rest = Enum.reject(profiles, fn p -> Enum.any?(p.team_ids, &MapSet.member?(covered, &1)) end)

    if overridden == [] and rest == [],
      do: nil,
      else: Enum.sum(Enum.map(overridden, & &1.daily_target)) + (sum(rest) || 0)
  end

  @doc """
  The target on `on`: `target` on a working day, `nil` otherwise.

      iex> Core.Dashboards.Targets.on(35, ~D[2026-11-14], [1, 2, 3, 4, 5])
      nil
      iex> Core.Dashboards.Targets.on(35, ~D[2026-11-13], [1, 2, 3, 4, 5])
      35
  """
  @spec on(non_neg_integer() | nil, Date.t(), [1..7]) :: non_neg_integer() | nil
  def on(target, %Date{} = on, working_days),
    do: if(Windows.working?(on, working_days), do: target, else: nil)

  # Each profile once.
  defp sum([]), do: nil

  defp sum(profiles),
    do: profiles |> Enum.uniq_by(& &1.profile_id) |> Enum.map(& &1.daily_target) |> Enum.sum()
end
