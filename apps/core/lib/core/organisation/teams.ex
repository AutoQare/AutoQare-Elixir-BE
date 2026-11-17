defmodule Core.Organisation.Teams do
  @moduledoc """
  Teams, their members and their settings (AQ-01 §4.2, §6.2).

  AQ-04A §8.5 settles who: **the system admin** makes, renames and archives
  teams and changes roles; **a team lead** runs their team's settings and
  removes its staff (never another lead: "Only the system admin can do
  that.") and sets a member's daily target (AQ-11 §5); a member reads. One guard, tested: **a team keeps at least one
  lead while it has members**.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Broadcast
  alias Core.Dashboards
  alias Core.Notifications.Account, as: AccountNotices
  alias Core.Realtime
  alias Data.Accounts
  alias Data.Customers
  alias Data.Repo
  alias Data.Scope
  alias Data.Teams
  alias Data.Teams.Team
  alias Data.Teams.TeamMember
  alias Data.Teams.TeamSettings

  @team_fields ~w(name slug archived_at)a

  # ── Teams ───────────────────────────────────────────────────────────────────

  @doc "`GET /teams`: every team for the system admin, the caller's own otherwise."
  @spec list(Scope.t()) :: {:ok, [Team.t()]}
  def list(%Scope{organisation: organisation} = scope) do
    teams =
      if Scope.admin?(scope),
        do: Teams.list(organisation.id),
        else: Teams.list(organisation.id, ids: Scope.team_ids(scope))

    {:ok, Teams.with_member_counts(teams)}
  end

  @doc "`GET /teams/:id`, with its member count."
  @spec get(Scope.t(), binary()) :: {:ok, Team.t()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, team} <- fetch(scope, :read, id), do: {:ok, counted(team)}
  end

  # Every team a route answers carries `member_count`.
  defp counted(%Team{} = team), do: hd(Teams.with_member_counts([team]))

  defp fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Team{} = team <- Teams.get(organisation.id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:team, team}) do
      {:ok, team}
    end
  end

  @doc "`POST /teams {name}`."
  @spec create(Scope.t(), map()) :: {:ok, Team.t()} | {:error, term()}
  def create(%Scope{organisation: organisation} = scope, params) do
    with :ok <- Access.why_not(scope, :create, {:team, %{}}) do
      attrs = params |> take(~w(name slug)) |> Map.put("organisation_id", organisation.id)
      Repo.transaction(fn -> insert_team(scope, attrs) end)
    end
  end

  defp insert_team(scope, attrs) do
    with {:ok, team} <- Teams.create(attrs),
         {:ok, _settings} <- Teams.put_settings(team.id, %{}) do
      {:ok, _event} = Audit.record(scope, "created", team, after: snapshot(team))
      counted(team)
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "`PATCH /teams/:id {name}`."
  @spec update(Scope.t(), binary(), map()) :: {:ok, Team.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    with {:ok, team} <- fetch(scope, :update, id) do
      Repo.transaction(fn -> write_team(scope, team, take(params, ~w(name slug))) end)
    end
  end

  defp write_team(scope, team, attrs) do
    case Teams.update(team, attrs) do
      {:ok, updated} ->
        {:ok, _event} =
          Audit.record(scope, "updated", updated,
            before: snapshot(team),
            after: snapshot(updated)
          )

        counted(updated)

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "`POST /teams/:id/archive`."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Team.t()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, team} <- fetch(scope, :archive, id) do
      Repo.transaction(fn ->
        {:ok, archived} = Teams.archive(team, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(team),
            after: snapshot(archived),
            now: now
          )

        counted(archived)
      end)
    end
  end

  # ── Settings ────────────────────────────────────────────────────────────────

  @doc "`GET /teams/:id/settings`: the three `peer_*` levels and three customer toggles, for a lead or above."
  @spec get_settings(Scope.t(), binary()) :: {:ok, TeamSettings.t()} | {:error, term()}
  def get_settings(%Scope{} = scope, id) do
    with {:ok, team} <- fetch(scope, :read_settings, id), do: {:ok, Teams.get_settings(team.id)}
  end

  @doc "`PUT /teams/:id/settings`."
  @spec put_settings(Scope.t(), binary(), map()) :: {:ok, TeamSettings.t()} | {:error, term()}
  def put_settings(%Scope{} = scope, id, params) do
    with {:ok, team} <- fetch(scope, :update_settings, id) do
      attrs = take(params, Enum.map(TeamSettings.fields(), &to_string/1))

      fn -> write_settings(scope, team, attrs) end
      |> Repo.transaction()
      |> Broadcast.after_commit(fn _settings -> tell_boards(team) end)
    end
  end

  # Open boards re-read: what a member sees of peers' tasks, and the names a customer
  # reads, follow these settings.
  defp tell_boards(team) do
    customers = Customers.list(team.organisation_id, team_ids: [team.id])
    team.id |> Realtime.team_settings_events(Enum.map(customers, & &1.id)) |> Realtime.send_all()
  end

  defp write_settings(scope, team, attrs) do
    fields = TeamSettings.fields()
    before = Audit.snapshot(Teams.get_settings(team.id), fields)

    case Teams.put_settings(team.id, attrs) do
      {:ok, settings} ->
        after_map = settings |> Audit.snapshot(fields) |> Map.put("team_id", team.id)
        {:ok, _event} = Audit.record(scope, "updated", settings, before: before, after: after_map)
        settings

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # ── Members ─────────────────────────────────────────────────────────────────

  @doc """
  `GET /teams/:id/members`: the open memberships with their people, each
  with its `daily_target` and (AQ-11 §7.4) `target_today` at `now`.
  """
  @spec list_members(Scope.t(), binary(), DateTime.t()) ::
          {:ok, [TeamMember.t()]} | {:error, term()}
  def list_members(%Scope{} = scope, id, %DateTime{} = now \\ Core.Clock.now()) do
    with {:ok, team} <- fetch(scope, :list_members, id),
         do: {:ok, Dashboards.with_targets(scope, Teams.list_members(team.id), now)}
  end

  @doc """
  `PATCH /teams/:id/members/:user_id {daily_target: n | null}` (AQ-11 §5,
  §7.4): the member's own daily target in this team — `null` gives them
  back their profiles' sum — by the team's leads and the system admin
  (staff: "Only a team lead can do that in this team."); a number below 0
  is a field error. Audited. Answers the member with `target_today` at
  `now`.
  """
  @spec update_member(Scope.t(), binary(), binary(), map(), DateTime.t()) ::
          {:ok, TeamMember.t()} | {:error, term()}
  def update_member(%Scope{} = scope, team_id, user_id, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, team} <- fetch(scope, :set_target, team_id),
         true <- Map.has_key?(params, "daily_target") || {:error, {:missing, [:daily_target]}},
         %TeamMember{} = member <- Teams.get_open_member(team.id, user_id) || {:error, :not_found},
         {:ok, changed} <- set_target(scope, member, params, now) do
      [answer] = Dashboards.with_targets(scope, [%{changed | user: member.user, team: team}], now)
      {:ok, answer}
    end
  end

  defp set_target(scope, member, params, now) do
    Repo.transaction(fn ->
      case Teams.set_target(member, Map.take(params, ["daily_target"])) do
        {:ok, changed} ->
          {:ok, _event} =
            Audit.record(scope, "target_changed", changed,
              before: Map.put(member_snapshot(member), "daily_target", member.daily_target),
              after: Map.put(member_snapshot(changed), "daily_target", changed.daily_target),
              now: now
            )

          changed

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Puts somebody in a team as `role`. **Not a route**: a person joins by
  accepting an invitation (`Core.Organisation.Invitations.accept/3`), which
  calls this inside its transaction. An open membership is kept as it is.
  """
  @spec add_member(Scope.t(), Team.t(), struct(), atom(), DateTime.t()) ::
          {:ok, TeamMember.t()} | {:error, term()}
  def add_member(%Scope{} = scope, %Team{} = team, user, role, %DateTime{} = now) do
    case Teams.get_open_member(team.id, user.id) do
      %TeamMember{} = member ->
        {:ok, member}

      nil ->
        with {:ok, member} <-
               Teams.add_member(%{team_id: team.id, user_id: user.id, role: role, joined_at: now}) do
          {:ok, _event} =
            Audit.record(scope, "joined", member, after: member_snapshot(member), now: now)

          # AQ-10B §5.1 A11: told unless they added themselves (accepting).
          :ok =
            Core.Notifications.send_events(
              AccountNotices.team_changed(scope, team, user.id, :added, now)
            )

          {:ok, %{member | user: Accounts.with_person(user), team: team}}
        end
    end
  end

  @doc """
  `POST /teams/:id/members/:user_id/role {role: lead | member}`: the system
  admin's (AQ-04A §8.5); the team keeps a lead.
  """
  @spec change_role(Scope.t(), binary(), binary(), String.t() | atom()) ::
          {:ok, TeamMember.t()} | {:error, term()}
  def change_role(%Scope{} = scope, team_id, user_id, role) do
    with {:ok, team} <- fetch(scope, :change_role, team_id),
         {:ok, role} <- role(role),
         %TeamMember{} = member <- Teams.get_open_member(team.id, user_id) || {:error, :not_found},
         :ok <- keeps_a_lead(team, member, role) do
      Repo.transaction(fn ->
        {:ok, changed} = Teams.change_role(member, role)

        {:ok, _event} =
          Audit.record(scope, "role_changed", changed,
            before: member_snapshot(member),
            after: member_snapshot(changed)
          )

        {%{changed | user: member.user, team: team}, role_told(scope, team, member, changed)}
      end)
      |> sent()
      |> with_target(scope)
    end
  end

  defp with_target({:ok, member}, scope),
    do: {:ok, hd(Dashboards.with_targets(scope, [member], Core.Clock.now()))}

  defp with_target(other, _scope), do: other

  @doc """
  `DELETE /teams/:id/members/:user_id`: the membership ends (`left_at`); the
  row stays. The system admin removes anyone; a team lead removes staff of
  their team, never another lead (AQ-04A §8.5).
  """
  @spec remove_member(Scope.t(), binary(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def remove_member(%Scope{} = scope, team_id, user_id, %DateTime{} = now) do
    with {:ok, team} <- fetch(scope, :remove_member, team_id),
         %TeamMember{} = member <- Teams.get_open_member(team.id, user_id) || {:error, :not_found},
         :ok <- within_reach(scope, member.role),
         :ok <- keeps_a_lead(team, member, nil) do
      Repo.transaction(fn ->
        {:ok, left} = Teams.leave(member, now)

        {:ok, _event} =
          Audit.record(scope, "removed", left, before: member_snapshot(member), now: now)

        {:ok, AccountNotices.team_changed(scope, team, member.user_id, :removed, now)}
      end)
      |> sent()
      |> elem(1)
    end
  end

  # AQ-10B §5.1 A11: a role changed is told to its person.
  defp role_told(_scope, _team, %{role: role}, %{role: role}), do: []

  defp role_told(scope, team, member, changed),
    do:
      AccountNotices.team_changed(
        scope,
        team,
        member.user_id,
        {:role, changed.role},
        Core.Clock.now()
      )

  defp role(role) when is_atom(role) and role in [:lead, :member], do: {:ok, role}

  defp role(role) when is_binary(role) do
    if role in Data.Vocabulary.team_member_roles(),
      do: {:ok, String.to_existing_atom(role)},
      else: {:error, {:missing, :role}}
  end

  defp role(_role), do: {:error, {:missing, :role}}

  # A team lead removes staff, never another lead: that is the system admin's.
  defp within_reach(scope, role) do
    if Scope.admin?(scope) or role != :lead,
      do: :ok,
      else: {:error, {:forbidden, Access.admin_words()}}
  end

  # The team keeps a lead while it has members. `new_role` is
  # nil for a removal.
  defp keeps_a_lead(team, member, new_role) do
    others = team.id |> Teams.list_members() |> Enum.reject(&(&1.id == member.id))
    stays? = others == [] and is_nil(new_role)

    led? =
      Enum.any?(others, &TeamMember.leads?(&1.role)) or (new_role && TeamMember.leads?(new_role))

    if stays? or led?,
      do: :ok,
      else:
        {:error,
         {:forbidden, "The team needs a lead while it has members. Promote someone first."}}
  end

  defp take(params, keys),
    do: params |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(keys)

  defp snapshot(team), do: Audit.snapshot(team, @team_fields)

  defp member_snapshot(member),
    do: %{
      "team_id" => member.team_id,
      "user_id" => member.user_id,
      "role" => to_string(member.role)
    }

  defp sent({:ok, {value, events}}) do
    :ok = Core.Notifications.send_events(events)
    {:ok, value}
  end

  defp sent(other), do: other
end
