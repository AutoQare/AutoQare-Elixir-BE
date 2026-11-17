defmodule Core.Tasks.Board do
  @moduledoc """
  The console's board page (AQ-02 §7.2, §7.6; AQ-03B §5.1): **one team's
  board** (`team_id`, required) over the tasks the caller sees there
  (`Core.Tasks.Visibility`), the six columns in vocabulary order, Done and
  Closed showing 30 days with the older counted (`older_done`,
  `older_closed`), In progress grouped **by stage with `mine=true`, else by
  primary assignee** (QP2-10), and order within a column by the chosen sort
  (QP2-9: a drop changes the state only).

  P2's views and filters are the board's `$where` now
  (`Data.Filters.Tasks`, AQ-11B §11.4), every one in SQL: `mine`,
  `watching`, `customer_id` (a customer the caller may read; else 404),
  `archived`, `q`, `priority`, `due` (in the organisation's zone),
  `people`, `profile_id`, `stage_id`, `no_owner`. `$order` is
  `Data.Filters.TasksSort`'s (`due` · `priority` · `inserted_at`). `team_id`
  and `older` (`done` · `closed`) stay parameters; `view` is gone (422).

  `mine` changes the page's shape, not only its rows: my open steps on
  other tasks are step cards, and In progress groups by my stages. A
  member whose team's `peer_tasks` is `hidden` sees their own; with none,
  `empty: "team_hidden"`. `people` (the sheet's chips) and `empty` read the
  team's tasks under `mine`, `watching`, `customer_id` and `archived`
  alone, so narrowing the sheet never hides a person to pick.
  """

  alias Core.Access
  alias Core.Tasks.{Cards, Person, Visibility}
  alias Data.Customers
  alias Data.Filters
  alias Data.Scope
  alias Data.Tasks, as: Store
  alias Data.TaskStages
  alias Data.Teams

  @states Data.Tasks.Task.states()
  @older_days 30
  # What `people` and `empty` read: the board's shape, not the sheet's narrowing.
  @view ~w(mine watching customer_id archived)
  @people [participants: [user: [person: :photo]]]

  @doc "`GET /board?team_id&$where&$order&older`: the page."
  @spec page(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    where = params["$where"]

    with true <- Scope.staff?(scope) || {:error, :not_found},
         :ok <- no_view(params),
         {:ok, team} <- team(scope, params["team_id"]),
         :ok <- customer(scope, Filters.value(where, "customer_id")),
         context = Filters.context(scope, now: now),
         visible = Visibility.filter(scope),
         {:ok, tasks} <- Store.board(visible, team.id, where, params["$order"], context),
         {:ok, viewed} <-
           Store.board(
             visible,
             team.id,
             Map.take(Filters.default(where, "archived", false), @view),
             nil,
             context,
             @people
           ) do
      me = Scope.user_id(scope)
      view = view(where)
      ctx = Cards.context(scope, tasks, now)
      shown = entries(ctx, tasks, view, me)

      hidden? =
        Scope.team_role(scope, team.id) == :member and not Visibility.peers?(scope, team.id)

      {columns, older} = columns(shown, params["older"], now)
      stages = TaskStages.list(me)

      {:ok,
       %{
         counts: %{
           due_today:
             Enum.count(shown, fn {task, _item} -> open?(task) and due_today?(task, ctx) end),
           overdue: Enum.count(shown, fn {task, _item} -> Cards.overdue?(task, ctx) end),
           by_state: Map.new(columns, fn {state, items} -> {state, length(items)} end),
           older_done: older.done,
           older_closed: older.closed
         },
         columns:
           Enum.map(
             @states,
             &%{state: &1, items: Enum.map(columns[&1], fn {_t, item} -> item end)}
           ),
         in_progress_groups: groups(view, columns[:in_progress], stages),
         stages: Enum.map(stages, &%{id: &1.id, name: &1.name, position: &1.position}),
         people: people(viewed),
         team: %{id: team.id, name: team.name},
         teams: teams(scope),
         empty: empty(view, hidden?, viewed)
       }}
    end
  end

  # ── The team and the filters ────────────────────────────────────────────────

  # AQ-03B §5.1: the views became filters; `view` is refused rather than ignored.
  defp no_view(%{"view" => _any}),
    do: {:error, {:invalid, %{"view" => ["is gone: use mine, watching or customer_id"]}}}

  defp no_view(_params), do: :ok

  # The team: required; a live team the caller is in, or any for an admin.
  defp team(scope, team_id) do
    case Utils.presence(to_string(team_id || "")) do
      nil ->
        {:error, {:invalid, %{"team_id" => ["is required"]}}}

      id ->
        with %{archived_at: nil} = team <- Teams.get(Scope.organisation_id(scope), id),
             true <- Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team.id)) do
          {:ok, team}
        else
          _other -> {:error, :not_found}
        end
    end
  end

  # `:mine` with `mine` (step cards, grouped by stage), `:customer` with
  # `customer_id`, else `:team`.
  defp view(where) do
    cond do
      on?(Filters.value(where, "mine")) -> :mine
      equal(Filters.value(where, "customer_id")) not in [nil, ""] -> :customer
      true -> :team
    end
  end

  # A customer the caller may read, or 404 (P2's rule); a malformed id is
  # `Data.Filters`' 422.
  defp customer(scope, value) do
    with id when is_binary(id) <- equal(value),
         {:ok, id} <- Ecto.UUID.cast(id),
         %{} = customer <- Customers.get(Scope.organisation_id(scope), id) || {:error, :not_found} do
      Access.why_not(scope, :read, {:customer, customer})
    else
      {:error, _reason} = error -> error
      _not_one -> :ok
    end
  end

  defp equal(%{"$EQUAL" => id}), do: id
  defp equal(%{"$equal" => id}), do: id
  defp equal(id) when is_binary(id), do: id
  defp equal(_other), do: nil

  # Mine keeps what is mine as cards and my open steps on the rest as step
  # cards; otherwise every task is its card.
  defp entries(ctx, tasks, :mine, me), do: Enum.flat_map(tasks, &mine(ctx, &1, me))
  defp entries(ctx, tasks, _view, _me), do: Enum.map(tasks, &{&1, Cards.card(ctx, &1)})

  defp mine(ctx, task, me) do
    if Cards.mine?(task, me) or (task.state == :draft and task.author_user_id == me),
      do: [{task, Cards.card(ctx, task)}],
      else:
        for(
          step <- task.steps,
          step.assignee_user_id == me and is_nil(step.done_at),
          do: {task, Cards.step_card(ctx, task, step)}
        )
  end

  # ── What the counts read ────────────────────────────────────────────────────

  defp due_today?(task, ctx), do: due_day(task, ctx) == ctx.today

  defp due_day(%{due_on: %Date{} = on}, _ctx), do: on

  defp due_day(%{due_at: %DateTime{} = at}, ctx) do
    case DateTime.shift_zone(at, ctx.zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(at)
    end
  end

  defp due_day(_task, _ctx), do: nil

  # Done and Closed show 30 days unless `older` opens them.
  defp columns(entries, older, now) do
    cutoff = DateTime.add(now, -@older_days, :day)
    by_state = Enum.group_by(entries, fn {t, _i} -> t.state end)

    older? = fn {t, _i} ->
      at = t.done_at || t.closed_at
      at && DateTime.compare(at, cutoff) == :lt
    end

    {done_old, done} = Enum.split_with(Map.get(by_state, :done, []), older?)
    {closed_old, closed} = Enum.split_with(Map.get(by_state, :closed, []), older?)

    columns =
      @states
      |> Map.new(&{&1, Map.get(by_state, &1, [])})
      |> Map.put(:done, if(older == "done", do: done ++ done_old, else: done))
      |> Map.put(:closed, if(older == "closed", do: closed ++ closed_old, else: closed))

    {columns, %{done: length(done_old), closed: length(closed_old)}}
  end

  # ── Groups, people, teams ───────────────────────────────────────────────────

  defp groups(:mine, entries, stages) do
    by_stage = Enum.group_by(entries, fn {t, _i} -> t.stage_id end)
    mine = MapSet.new(stages, & &1.id)

    staged =
      for s <- stages, items = Map.get(by_stage, s.id, []), items != [] do
        %{
          key: s.id,
          label: s.name,
          stage: %{id: s.id, name: s.name},
          person: nil,
          items: items(items)
        }
      end

    rest = Enum.reject(entries, fn {t, _i} -> t.stage_id && MapSet.member?(mine, t.stage_id) end)
    staged ++ last("none", "No stage", rest)
  end

  defp groups(_view, entries, _stages) do
    by_primary = Enum.group_by(entries, fn {t, _i} -> primary(t) end)

    named =
      by_primary
      |> Enum.reject(fn {user, _items} -> is_nil(user) end)
      |> Enum.sort_by(fn {user, _items} -> user.person.display_name end)
      |> Enum.map(fn {user, items} ->
        %{
          key: user.id,
          label: user.person.display_name,
          stage: nil,
          person: Person.view(user),
          items: items(items)
        }
      end)

    named ++ last("nobody", "Nobody yet", Map.get(by_primary, nil, []))
  end

  defp last(_key, _label, []), do: []

  defp last(key, label, entries),
    do: [%{key: key, label: label, stage: nil, person: nil, items: items(entries)}]

  defp items(entries), do: Enum.map(entries, fn {_t, item} -> item end)

  defp primary(task), do: Enum.find_value(task.participants, &(&1.level == :primary && &1.user))

  defp people(tasks) do
    tasks
    |> Enum.flat_map(fn t -> for p <- t.participants, p.level, do: p.user end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.person.display_name)
    |> Enum.map(&Person.view/1)
  end

  # The caller's teams, with their role in each; an admin sees every team.
  defp teams(scope) do
    ids = if Scope.admin?(scope), do: nil, else: Scope.team_ids(scope)

    scope
    |> Scope.organisation_id()
    |> Teams.list(if(ids, do: [ids: ids], else: []))
    |> Enum.map(&%{id: &1.id, name: &1.name, role: Scope.team_role(scope, &1.id) || :admin})
  end

  defp empty(_view, true, []), do: "team_hidden"
  defp empty(view, _hidden, []), do: Atom.to_string(view)
  defp empty(_view, _hidden, _entries), do: nil

  defp open?(task), do: task.state in [:todo, :in_progress, :on_hold]

  defp on?(%{} = value), do: on?(equal(value))
  defp on?(value), do: value in [true, "true"]
end
