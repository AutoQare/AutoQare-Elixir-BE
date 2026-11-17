defmodule Core.Dashboards do
  @moduledoc """
  **The one counter** (AQ-11 §4, §7.4, QP11-9, QP11-12): every number on
  the console's *Dashboard*, the portal's *Home* and P10b's weekly summary
  and report is counted here, so an email and a tile never disagree.
  Computed on read, one query per set of windows (`Data.Dashboards`);
  the windows are calendar days in the organisation's zone
  (`Core.Dashboards.Windows`), the kinds `Core.Dashboards.Rules`', rates
  `Core.Dashboards.Rates`', targets `Core.Dashboards.Targets`'.

  | Route | Built by |
  |---|---|
  | `GET /team/v1/dashboard/me?period` | `me/3` (`Core.Dashboards.Me`) |
  | `GET /team/v1/dashboard/team?team_id&period&cohort` · `team.csv` | `team/3`, `team_csv/3` (`Core.Dashboards.Team`) |
  | `GET /client/v1/home` | `home/2` (`Core.Dashboards.Home`) |

  **Whose** (`who`): `{:person, user_id}` — the applications they made
  (the `applied` rows they are the actor of) and the leads they own (for
  interviews); `{:team, team_ids}` (`nil`: every team) and `{:customer,
  customer_id}` — every lead there, whoever made it. **A number about a
  lead the caller may not see counts in a team's totals**; only the lists
  are cut to what the caller reads (§6). The counters count as told: the
  route functions decide who may ask.
  """

  alias Core.Dashboards.{Home, Me, Rates, Rules, Targets, Team, Windows}
  alias Core.Leads.Signals
  alias Data.Dashboards, as: Store
  alias Data.Dashboards.Rows
  alias Data.Scope

  @type who :: {:person, binary()} | {:team, [binary()] | nil} | {:customer, binary()}

  # ── The routes ──────────────────────────────────────────────────────────────

  @doc "`GET /team/v1/dashboard/me?period=today|week|month`: *My numbers*."
  @spec me(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  defdelegate me(scope, params, now), to: Me, as: :build

  @doc "`GET /team/v1/dashboard/team?team_id&period&cohort`: *Team*."
  @spec team(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  defdelegate team(scope, params, now), to: Team, as: :build

  @doc "`GET /team/v1/dashboard/team.csv`: `{:ok, csv, filename}`."
  @spec team_csv(Scope.t(), map(), DateTime.t()) :: {:ok, iodata(), String.t()} | {:error, term()}
  defdelegate team_csv(scope, params, now), to: Team, as: :csv

  @doc "`GET /client/v1/home`: the customer's *Home*."
  @spec home(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  defdelegate home(scope, now), to: Home, as: :build

  # ── The counters ────────────────────────────────────────────────────────────

  @doc """
  Applications in each window (`%{key => {from, to}}`) and how many have
  since had a response: `%{key => %{count, responses}}`; with `group`
  (`:profile`, `:platform`, `:skill`, `:actor`) a row per group.
  """
  @spec applications(Scope.t(), who(), map(), atom() | nil) :: map() | [map()]
  def applications(%Scope{} = scope, who, windows, group \\ nil),
    do: Store.applications(applied_subject(scope, who), windows, Rules.counting(), group)

  @doc "Leads with an interview in each window: `%{key => n}`; with `group: :owner` a row per owner."
  @spec interviews(Scope.t(), who(), map(), atom() | nil) :: map() | [map()]
  def interviews(%Scope{} = scope, who, windows, group \\ nil),
    do: Store.interviews(lead_subject(scope, who), windows, Rules.counting(), group)

  @doc """
  A cohort's funnel (§4, QP11-6): `[%{key, count, rate_bp}]` for *Applied →
  Responded → Interview → Offer → Hired*, each rate from the step before
  (*Applied*'s is 100% of itself; `nil` when nothing applied).
  """
  @spec funnel(Scope.t(), who(), map()) :: [map()]
  def funnel(%Scope{} = scope, who, cohort) do
    counts =
      Store.funnel(
        lead_subject(scope, who),
        {cohort.from, cohort.to},
        {cohort.first, cohort.last},
        Rules.counting()
      )

    steps = [:applied, :responded, :interview, :offer, :hired]

    steps
    |> Enum.with_index()
    |> Enum.map(fn {key, i} ->
      before = if i == 0, do: counts.applied, else: counts[Enum.at(steps, i - 1)]
      %{key: key, count: counts[key], rate_bp: Rates.rate_bp(counts[key], before)}
    end)
  end

  @doc """
  The three numbers of a period for `who` in `window`: `%{applications,
  responses: %{count, of, rate_bp, few}, interviews}` — the tiles, and
  what the weekly emails say.
  """
  @spec numbers(Scope.t(), who(), Windows.window()) :: map()
  def numbers(%Scope{} = scope, who, window) do
    %{period: apps} = applications(scope, who, %{period: window})
    %{period: interviews} = interviews(scope, who, %{period: window})

    %{
      applications: apps.count,
      responses: Rates.of(apps.responses, apps.count),
      interviews: interviews
    }
  end

  @doc """
  A week for the weekly emails (AQ-10B §5.1 A13, §5.3 L9): the calendar
  week before `monday` in the organisation's zone — its applications,
  responses and interviews, as the tiles count them — and the scheduled
  meetings from `now` to the end of `monday`'s week.
  """
  @spec week(Scope.t(), who(), Date.t(), DateTime.t()) :: map()
  def week(%Scope{} = scope, who, %Date{} = monday, %DateTime{} = now) do
    zone = zone(scope)

    numbers =
      numbers(scope, who, Windows.window(Date.add(monday, -7), Date.add(monday, -1), zone))

    ahead = {now, Windows.start_of(Date.add(monday, 7), zone)}

    %{
      applications: numbers.applications,
      responses: numbers.responses.count,
      interviews: numbers.interviews,
      upcoming: length(Rows.meetings(lead_subject(scope, who), ahead))
    }
  end

  @doc "The employers' replies in `window` on `who`'s leads in `team_ids` (the customer's report)."
  @spec replies(Scope.t(), who(), [binary()], Windows.window()) :: non_neg_integer()
  def replies(%Scope{} = scope, who, team_ids, window),
    do: Rows.reply_count(lead_subject(scope, who), team_ids, window)

  @doc """
  *To sort in Triage* (§4): each person's count of the triage items on
  their profiles in `team_ids`, `%{user_id => n}`, and the teams' total.
  """
  @spec triage(Scope.t(), [binary()]) :: {%{binary() => non_neg_integer()}, non_neg_integer()}
  def triage(%Scope{} = _scope, team_ids) do
    by_person =
      team_ids
      |> Store.triage_owners()
      |> Enum.uniq_by(&{&1.conversation_id, &1.user_id})
      |> Enum.frequencies_by(& &1.user_id)

    {by_person, Store.triage_count(team_ids)}
  end

  # ── Targets ─────────────────────────────────────────────────────────────────

  @doc """
  Team members with `target_today` filled (§5): each one's target in their
  team on `now`'s day, `nil` on a day off or with no target.
  """
  @spec with_targets(Scope.t(), [map()], DateTime.t()) :: [map()]
  def with_targets(%Scope{} = scope, members, %DateTime{} = now) do
    today = Windows.today(now, zone(scope))
    days = working_days(scope)
    owned = owned(Enum.map(members, & &1.user_id))

    Enum.map(members, fn m ->
      target = Targets.in_team(m.daily_target, Map.get(owned, m.user_id, []), m.team_id)
      %{m | target_today: Targets.on(target, today, days)}
    end)
  end

  @doc "A person's own target (their memberships' overrides and owned profiles), before working days."
  @spec person_target(Scope.t(), binary()) :: non_neg_integer() | nil
  def person_target(%Scope{} = _scope, user_id) do
    memberships = Data.Teams.memberships_of(user_id)
    Targets.person(memberships, Map.get(owned([user_id]), user_id, []))
  end

  @doc false
  def owned(user_ids), do: user_ids |> Rows.owned_profiles() |> Enum.group_by(& &1.user_id)

  # ── Helpers the parts share ─────────────────────────────────────────────────

  @doc "The organisation's zone."
  @spec zone(Scope.t()) :: String.t()
  def zone(%Scope{organisation: organisation}), do: Signals.zone(organisation)

  @doc "The organisation's working days (ISO weekdays)."
  @spec working_days(Scope.t()) :: [1..7]
  def working_days(%Scope{} = scope),
    do: Data.Organisations.get_settings(Scope.organisation_id(scope)).working_days

  @doc "The subject `Data.Dashboards` narrows leads by."
  @spec lead_subject(Scope.t(), who()) :: map()
  def lead_subject(scope, {:person, user_id}), do: base(scope, owner_user_id: user_id)
  def lead_subject(scope, {:team, team_ids}), do: base(scope, team_ids: team_ids)
  def lead_subject(scope, {:customer, id}), do: base(scope, customer_id: id)

  @doc "The subject `Data.Dashboards` narrows applications by: a person is who applied."
  @spec applied_subject(Scope.t(), who()) :: map()
  def applied_subject(scope, {:person, user_id}), do: base(scope, actor_user_id: user_id)
  def applied_subject(scope, who), do: lead_subject(scope, who)

  defp base(scope, narrowing),
    do: Map.new([{:organisation_id, Scope.organisation_id(scope)} | narrowing])

  @doc "A person as the dashboards name one: `%{id, name}`, or `nil`."
  @spec person(map() | nil) :: map() | nil
  def person(%{id: id, person: %{display_name: name}}), do: %{id: id, name: name}
  def person(_nobody), do: nil

  @doc "A lead's title with its company: \"Backend Developer · Bamboo Invest\"."
  @spec lead_title(map()) :: String.t()
  def lead_title(%{job: %{title: title, company: %{name: name}}}), do: title <> " · " <> name
  def lead_title(%{job: %{title: title}}), do: title

  @doc "A lead's company name, or `nil`."
  @spec company(map()) :: String.t() | nil
  def company(%{job: %{company: %{name: name}}}), do: name
  def company(_lead), do: nil
end
