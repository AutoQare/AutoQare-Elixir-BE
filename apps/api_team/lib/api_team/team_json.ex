defmodule ApiTeam.TeamJSON do
  @moduledoc """
  The teams' shapes (AQ-01 §6.2). AQ-11 §7.4: a member carries
  `daily_target` (their own override, or `null`) and `target_today` (their
  target today, `null` on a day off or with none).
  """

  alias Data.Teams.TeamSettings

  def index(%{teams: teams}), do: Enum.map(teams, &team/1)

  def show(%{team: team}), do: team(team)

  def settings(%{settings: settings}) do
    Map.new(TeamSettings.fields(), &{&1, Map.get(settings, &1)})
  end

  def members(%{members: members}), do: Enum.map(members, &member_json/1)

  def member(%{member: member}), do: member_json(member)

  defp team(team) do
    %{
      id: team.id,
      name: team.name,
      slug: team.slug,
      member_count: team.member_count,
      archived_at: team.archived_at,
      inserted_at: team.inserted_at
    }
  end

  defp member_json(m) do
    %{
      user_id: m.user_id,
      team_id: m.team_id,
      display_name: m.user.person.display_name,
      email: m.user.email,
      role: m.role,
      joined_at: m.joined_at,
      left_at: m.left_at,
      daily_target: m.daily_target,
      target_today: m.target_today
    }
  end
end
