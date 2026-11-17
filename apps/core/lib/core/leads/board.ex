defmodule Core.Leads.Board do
  @moduledoc """
  `GET /leads/board?team_id&view&pipeline&lane&older&$where` (AQ-04A §8.1,
  §8.3): **one team's leads** as columns.

  - **Collapsed** (the default): To do · In progress · On hold · Done; In
    progress sorted by stage position, then by activity.
  - **Expanded**, one pipeline at a time (`pipeline` required): To do, one
    column per stage of the live version, then any **retired** stage that
    still holds leads (`stage.retired: true`, QP4a-3), On hold, Done. A
    lead on an older version sits in the column of its stage's key.
  - **Done** shows 30 days (by `finished_at`); `older_done` counts the rest.
  - `empty`: `"team_hidden"` for a member at `peer_leads: hidden` with
    nothing of their own; `"mine"` for `owner {$EQUAL: "me"}` with
    nothing; `"team"` for a team with no lead at all; else `null`
    (nothing matches the filters).

  `team_id` is required (P3b's 422 and 404). A member at `hidden` sees only
  their own leads. **`$where` is `Data.Filters.Leads`'**, shared with the
  Tracker (a field, operator or value it doesn't take is the 422
  `invalid_filter`); `view`, `pipeline` (the expanded view's columns,
  which also narrows to that pipeline), `lane` and `older` are the board's
  own switches.
  """

  alias Core.Access
  alias Core.Access.Leads, as: LeadAccess
  alias Core.Dashboards.Rules
  alias Core.Jobs
  alias Core.Leads.{Pipelines, Sheet, Signals}
  alias Core.Tasks.Person
  alias Data.Leads, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @done_days 30

  @doc "The board: `{team, view, pipeline, columns, older_done, empty}`."
  @spec show(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def show(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, view} <- view(params["view"]),
         {:ok, pipeline} <- pipeline(scope, view, params["pipeline"]),
         {:ok, lane} <- lane(params["lane"]),
         where = with_pipeline(params["$where"], pipeline),
         {:ok, leads, ctx} <- leads(scope, team, where, now) do
      reach = LeadAccess.board_reach(scope, team.id)
      today = Sheet.today(scope, now)
      older? = params["older"] in [true, "true"]
      cards = %{today: today, ctx: ctx, now: now, older?: older?}
      {columns, older} = columns(view, pipeline, leads, cards)

      {:ok,
       %{
         team: %{id: team.id, name: team.name},
         view: view,
         pipeline: pipeline && Pipelines.view(scope, pipeline),
         columns: columns,
         older_done: older,
         empty: empty(leads, reach, where, team.id, context(scope, team, now)),
         lane: lane,
         lanes: lanes(lane, view, pipeline, leads, cards)
       }}
    end
  end

  defp view(nil), do: {:ok, :collapsed}
  defp view("collapsed"), do: {:ok, :collapsed}
  defp view("expanded"), do: {:ok, :expanded}
  defp view(_other), do: invalid("view", "is collapsed or expanded")

  defp pipeline(_scope, :collapsed, _key), do: {:ok, nil}

  defp pipeline(_scope, :expanded, nil),
    do: invalid("pipeline", "is required with the expanded view")

  defp pipeline(scope, :expanded, key) do
    case Enum.find(Pipelines.keys(), &(to_string(&1) == to_string(key))) do
      nil -> invalid("pipeline", "is employment or freelance")
      key -> {:ok, Pipelines.live(scope, key)}
    end
  end

  # ── Columns ─────────────────────────────────────────────────────────────────

  defp columns(:collapsed, nil, leads, cards) do
    by_state = Enum.group_by(leads, & &1.state)
    {done, older} = done(Map.get(by_state, :done, []), cards)

    in_progress =
      by_state
      |> Map.get(:in_progress, [])
      |> Enum.sort_by(&{position(&1), -DateTime.to_unix(&1.last_activity_at, :microsecond)})

    {[
       column("todo", :todo, nil, Map.get(by_state, :todo, []), cards),
       column("in_progress", :in_progress, nil, in_progress, cards),
       column("on_hold", :on_hold, nil, Map.get(by_state, :on_hold, []), cards),
       column("done", :done, nil, done, cards)
     ], older}
  end

  defp columns(:expanded, version, leads, cards) do
    by_state = Enum.group_by(leads, & &1.state)
    in_progress = Map.get(by_state, :in_progress, [])
    by_key = Enum.group_by(in_progress, & &1.stage.key)
    live_keys = Enum.map(version.stages, & &1.key)

    stages =
      for stage <- version.stages do
        column(
          stage.key,
          :in_progress,
          Pipelines.stage(stage),
          Map.get(by_key, stage.key, []),
          cards
        )
      end

    retired =
      for {key, [first | _] = held} <- by_key, key not in live_keys do
        stage = first.stage |> Pipelines.stage() |> Map.put(:retired, true)
        column(key, :in_progress, stage, held, cards)
      end
      |> Enum.sort_by(& &1.stage.position)

    {done, older} = done(Map.get(by_state, :done, []), cards)

    {[column("todo", :todo, nil, Map.get(by_state, :todo, []), cards)] ++
       stages ++
       retired ++
       [
         column("on_hold", :on_hold, nil, Map.get(by_state, :on_hold, []), cards),
         column("done", :done, nil, done, cards)
       ], older}
  end

  defp column(key, state, stage, leads, cards) do
    %{
      key: key,
      state: state,
      stage: stage,
      cards: Enum.map(leads, &card(&1, cards)),
      count: length(leads)
    }
  end

  defp card(lead, %{today: today, ctx: ctx}),
    do: Sheet.card(lead, today, Signals.for_lead(ctx, lead))

  # Done shows 30 days; the rest is counted behind "Older · N" — and with
  # `older=true` (AQ-04B §8.1) Done shows every one of them, newest first.
  defp done(leads, %{older?: true}),
    do: {Enum.sort_by(leads, & &1.finished_at, {:desc, DateTime}), 0}

  defp done(leads, %{now: now}) do
    since = DateTime.add(now, -@done_days * 86_400, :second)
    {recent, older} = Enum.split_with(leads, &(DateTime.compare(&1.finished_at, since) != :lt))
    {Enum.sort_by(recent, & &1.finished_at, {:desc, DateTime}), length(older)}
  end

  defp position(%{stage: %{position: position}}), do: position
  defp position(_lead), do: 0

  defp empty([], {:own, me}, _where, team_id, context) do
    if Store.for_team(team_id, nil, context, visible_to: me) == {:ok, []},
      do: "team_hidden",
      else: nil
  end

  defp empty([], _reach, where, team_id, context) do
    archived = Data.Filters.value(where, "archived") || %{"$EQUAL" => false}

    cond do
      Data.Filters.value(where, "owner") in ["me", %{"$EQUAL" => "me"}] -> "mine"
      Store.for_team(team_id, %{"archived" => archived}, context) == {:ok, []} -> "team"
      true -> nil
    end
  end

  defp empty(_leads, _reach, _where, _team_id, _context), do: nil

  # ── The leads (shared with the Tracker) ─────────────────────────────────────

  @doc false
  # The team's leads the caller reaches (`peer_leads`), narrowed by `where`
  # (`Data.Filters.Leads`), with their signals: `{:ok, leads, signals}`.
  # `follow_up {$EQUAL: "due"}` is P4b's rule (`Core.Leads.FollowUps`, pure
  # Elixir): the SQL keeps In progress and live, and the rest runs here on
  # the signals every card and row reads anyway — the same test *My
  # numbers* counts with — so it is a top-level filter only.
  def leads(scope, team, where, now, opts \\ []) do
    reach = LeadAccess.board_reach(scope, team.id)
    visible = if match?({:own, _}, reach), do: elem(reach, 1), else: :all

    with :ok <- top_level(where, "follow_up"),
         {:ok, leads} <-
           Store.for_team(
             team.id,
             where,
             context(scope, team, now),
             Keyword.put(opts, :visible_to, visible)
           ) do
      ctx = Signals.context(scope.organisation, leads, now)
      {:ok, follow_ups(leads, ctx, Data.Filters.value(where, "follow_up")), ctx}
    end
  end

  @doc false
  # What `Data.Filters.Leads`' overrides read: who is asking, `now`, the
  # zone, the team and the dashboards' counting kinds (shared with the
  # Tracker's `applications`).
  def context(scope, team, now),
    do: Data.Filters.context(scope, now: now, team_id: team.id, rules: Rules.counting())

  defp follow_ups(leads, _ctx, nil), do: leads

  defp follow_ups(leads, ctx, _due),
    do: Enum.filter(leads, &(Signals.follow_up(ctx, &1).state == :due))

  # A field the list finishes in Elixir can't sit inside `$OR` / `$AND`.
  defp top_level(where, field) do
    case Data.Filters.decode(where) do
      {:ok, map} ->
        nested =
          map
          |> Enum.filter(fn {key, _value} -> key in ["$OR", "$AND"] end)
          |> Enum.any?(fn {_key, value} -> names?(value, field) end)

        if nested,
          do:
            {:error,
             {:invalid_filter,
              %{field => ["is a filter of the whole list, not inside $OR or $AND"]}}},
          else: :ok

      {:error, _refusal} ->
        :ok
    end
  end

  defp names?(value, field) when is_map(value) and not is_struct(value),
    do: Map.has_key?(value, field) or Enum.any?(Map.values(value), &names?(&1, field))

  defp names?(value, field) when is_list(value), do: Enum.any?(value, &names?(&1, field))
  defp names?(_value, _field), do: false

  # The expanded view shows one pipeline: its leads alone.
  defp with_pipeline(where, nil), do: where

  defp with_pipeline(where, pipeline) do
    case Data.Filters.decode(where) do
      {:ok, map} -> Map.put(map, "pipeline", %{"$EQUAL" => to_string(pipeline.pipeline_key)})
      {:error, _refusal} -> where
    end
  end

  # ── Lanes (AQ-04B §9, QP4b-20) ──────────────────────────────────────────────

  defp lane(nil), do: {:ok, :none}
  defp lane(""), do: {:ok, :none}

  defp lane(value) do
    if to_string(value) in Vocabulary.board_lanes(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: invalid("lane", "is none, customer, profile, owner or source")
  end

  # Each lane is a row of the same columns with its own counts, by name.
  defp lanes(:none, _view, _pipeline, _leads, _cards), do: nil

  defp lanes(lane, view, pipeline, leads, cards) do
    leads
    |> Enum.group_by(&lane_of(lane, &1))
    |> Enum.map(fn {{key, name}, held} ->
      {columns, _older} = columns(view, pipeline, held, cards)
      %{key: key, name: name, count: length(held), columns: columns}
    end)
    |> Enum.sort_by(&{String.downcase(to_string(&1.name)), &1.key})
  end

  @doc false
  # A lead's lane (or the Tracker's group) as `{key, name}`.
  def lane_of(:customer, lead),
    do: {lead.profile.customer_id, lead.profile.customer.display_name}

  def lane_of(:profile, lead),
    do: {lead.profile_id, "#{lead.profile.customer.display_name} · #{lead.profile.title}"}

  def lane_of(:owner, lead),
    do: {lead.owner_user_id, Person.view(lead.owner_user).name}

  def lane_of(:source, lead), do: {to_string(lead.job.source), source_name(lead.job.source)}

  defp source_name(nil), do: "Other"

  defp source_name(source),
    do: source |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
