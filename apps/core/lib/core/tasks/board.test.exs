defmodule Core.Tasks.BoardTest do
  @moduledoc """
  The console's board page (AQ-02 §7.2, §7.6; AQ-03B §5.1): one team's
  board, its filters (`mine`, `watching`, `customer_id` and P2's), columns,
  groups, the words for empty.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Dashboards.Me
  alias Core.Tasks.Board
  alias Data.TaskStages

  @now ~U[2026-11-10 09:00:00.000000Z]
  @mine %{"mine" => %{"$EQUAL" => "true"}}
  @watching %{"watching" => %{"$EQUAL" => "true"}}

  defp customer(customer), do: %{"customer_id" => %{"$EQUAL" => customer.id}}

  setup do: board_cast_fixture()

  defp ids(page, state),
    do:
      page.columns
      |> Enum.find(&(&1.state == state))
      |> Map.fetch!(:items)
      |> Enum.map(&item_id/1)

  defp item_id(%{kind: "step", task: task}), do: {:step, task.id}
  defp item_id(%{id: id}), do: id

  test "Mine: assigned to me, my own unassigned and my drafts, my steps as step cards; watched behind the chip",
       c do
    fiza = scope_for(c.fiza)
    hira = scope_for(c.hira)
    mine = task_fixture(hira, team: c.backend, primary: c.fiza)
    own = task_fixture(fiza, team: c.backend)
    draft = task_fixture(fiza, team: c.backend, state: :draft)
    given_away = task_fixture(fiza, team: c.backend, primary: c.qasim)
    stepped = task_fixture(hira, team: c.backend, primary: c.hira)
    step_fixture(stepped, assignee: c.fiza, title: "Shortlist")
    watched = task_fixture(hira, team: c.backend, primary: c.hira, watchers: [c.fiza])

    assert {:ok, page} = Board.page(fiza, %{"team_id" => c.backend.id, "$where" => @mine}, @now)
    assert Enum.sort(ids(page, :todo)) == Enum.sort([mine.id, own.id, {:step, stepped.id}])
    assert ids(page, :draft) == [draft.id]
    refute given_away.id in ids(page, :todo)
    assert page.counts.by_state.todo == 3
    assert page.empty == nil
    assert Enum.map(page.columns, & &1.state) == Data.Tasks.Task.states()

    step =
      page.columns
      |> Enum.find(&(&1.state == :todo))
      |> Map.fetch!(:items)
      |> Enum.find(&(&1.kind == "step"))

    assert step.step.title == "Shortlist" and step.step.position == 1 and step.step.total == 1

    assert {:ok, page} =
             Board.page(fiza, %{"team_id" => c.backend.id, "$where" => @watching}, @now)

    assert ids(page, :todo) == [watched.id]

    muaz = scope_for(c.muaz)

    assert {:ok, %{empty: "mine"}} =
             Board.page(muaz, %{"team_id" => c.backend.id, "$where" => @mine}, @now)

    assert {:ok, page} =
             Board.page(
               muaz,
               %{"team_id" => c.backend.id, "$where" => Map.merge(@mine, @watching)},
               @now
             )

    assert page.empty == "mine"
  end

  test "the team: required, a lead sees it all, a member at hidden their own and the words, view and edit all",
       c do
    fiza = scope_for(c.fiza)
    peer = task_fixture(fiza, team: c.backend, primary: c.fiza)
    muaz_own = task_fixture(scope_for(c.muaz), team: c.backend, primary: c.muaz)

    assert {:ok, page} =
             Board.page(scope_for(c.bilal), %{"team_id" => c.backend.id}, @now)

    assert Enum.sort(ids(page, :todo)) == Enum.sort([peer.id, muaz_own.id])
    assert page.empty == nil and page.team == %{id: c.backend.id, name: "Backend squad"}

    backend = %{"team_id" => c.backend.id}
    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})
    assert {:ok, page} = Board.page(scope_for(c.muaz), backend, @now)
    assert ids(page, :todo) == [muaz_own.id]
    assert page.empty == nil

    assert {:ok, %{empty: "team_hidden"}} = Board.page(scope_for(c.qasim), backend, @now)

    for level <- [:view, :edit] do
      Data.Teams.put_settings(c.backend.id, %{peer_tasks: level})
      assert {:ok, page} = Board.page(scope_for(c.muaz), backend, @now)
      assert length(ids(page, :todo)) == 2 and page.empty == nil
    end

    assert {:ok, %{empty: "team"}} =
             Board.page(scope_for(c.hira), %{"team_id" => c.frontend.id}, @now)

    assert {:error, :not_found} =
             Board.page(scope_for(c.muaz), %{"team_id" => c.frontend.id}, @now)

    assert {:error, {:invalid, %{"team_id" => ["is required"]}}} =
             Board.page(scope_for(c.muaz), %{}, @now)

    assert {:error, {:invalid, %{"view" => [_words]}}} =
             Board.page(scope_for(c.muaz), Map.put(backend, "view", "team"), @now)

    assert {:ok, _admin_anywhere} =
             Board.page(scope_for(c.dawud), %{"team_id" => c.frontend.id}, @now)

    assert {:error, :not_found} = Board.page(customer_scope_for(c.tanweer), backend, @now)
  end

  test "In progress: by my stages with mine, No stage last; else by primary, Nobody yet last",
       c do
    {:ok, sourcing} = TaskStages.create(c.fiza.id, "Sourcing")
    hira = scope_for(c.hira)

    staged =
      task_fixture(hira, team: c.backend, primary: c.fiza, state: :in_progress, stage_id: nil)

    {:ok, _moved} = Data.Tasks.move(staged, %{state: :in_progress, stage_id: sourcing.id})
    plain = task_fixture(hira, team: c.backend, primary: c.fiza, state: :in_progress)
    nobody = task_fixture(hira, team: c.backend, state: :in_progress)

    assert {:ok, page} =
             Board.page(scope_for(c.fiza), %{"team_id" => c.backend.id, "$where" => @mine}, @now)

    assert [
             %{key: key, label: "Sourcing", items: [%{id: s}]},
             %{key: "none", label: "No stage", items: [%{id: p}]}
           ] =
             page.in_progress_groups

    assert {key, s, p} == {sourcing.id, staged.id, plain.id}
    assert [%{name: "Sourcing", position: 0}] = page.stages

    assert {:ok, page} = Board.page(hira, %{"team_id" => c.backend.id}, @now)

    assert [
             %{label: "Fiza", person: %{name: "Fiza"}, items: two},
             %{key: "nobody", label: "Nobody yet", items: [%{id: n}]}
           ] = page.in_progress_groups

    assert length(two) == 2 and n == nobody.id
  end

  test "filters, sort, Done's 30 days with the older counted, the customer filter", c do
    hira = scope_for(c.hira)

    urgent =
      task_fixture(hira,
        team: c.backend,
        customer: c.tanweer,
        priority: :urgent,
        due_on: ~D[2026-11-10],
        title: "Apply"
      )

    late =
      task_fixture(hira,
        team: c.backend,
        priority: :low,
        due_at: ~U[2026-11-09 09:00:00Z],
        title: "Call"
      )

    _plain = task_fixture(hira, team: c.backend, title: "Read")
    old = task_fixture(hira, team: c.backend, state: :done)

    Repo.update_all(from(t in Data.Tasks.Task, where: t.id == ^old.id),
      set: [done_at: ~U[2026-09-01 09:00:00Z]]
    )

    team = %{"team_id" => c.backend.id}

    assert {:ok, page} = Board.page(hira, Map.put(team, "$order", %{"due" => "$ASC"}), @now)
    assert [first, second | _rest] = ids(page, :todo)
    assert {first, second} == {late.id, urgent.id}
    assert page.counts.overdue == 1 and page.counts.due_today == 1
    assert page.counts.older_done == 1 and ids(page, :done) == []

    assert {:ok, page} = Board.page(hira, Map.merge(team, %{"older" => "done"}), @now)
    assert ids(page, :done) == [old.id]

    assert {:ok, page} = Board.page(hira, Map.put(team, "$order", %{"priority" => "$ASC"}), @now)
    assert hd(ids(page, :todo)) == urgent.id

    for {filter, expected} <- [
          {%{"q" => %{"$ILIKE" => "APP"}}, [urgent.id]},
          {%{"priority" => %{"$IN" => ["low", "urgent"]}}, [late.id, urgent.id]},
          {%{"due" => %{"$EQUAL" => "overdue"}}, [late.id]},
          {%{"due" => %{"$EQUAL" => "today"}}, [urgent.id]},
          {%{"no_owner" => %{"$EQUAL" => "true"}, "q" => %{"$ILIKE" => "call"}}, [late.id]}
        ] do
      assert {:ok, page} = Board.page(hira, Map.put(team, "$where", filter), @now)
      assert Enum.sort(ids(page, :todo)) == Enum.sort(expected), inspect(filter)
    end

    assert {:ok, page} =
             Board.page(hira, Map.put(team, "$where", customer(c.tanweer)), @now)

    assert ids(page, :todo) == [urgent.id]

    assert {:error, :not_found} =
             Board.page(
               scope_for(c.bilal),
               Map.put(team, "$where", customer(c.imran)),
               @now
             )

    assert [%{name: "Backend squad", role: :lead}, %{name: "Frontend squad", role: :lead}] =
             page.teams
  end

  test "Mine with due today or overdue counts what the dashboard's Tasks due counts (AQ-11 §4)",
       c do
    hira = scope_for(c.hira)
    fiza = scope_for(c.fiza)
    # 23:30 in Karachi on the 10th: the organisation's day, and the dashboard's.
    now = ~U[2026-11-10 18:30:00.000000Z]

    for attrs <- [
          [due_on: ~D[2026-11-10]],
          [due_at: ~U[2026-11-10 18:45:00Z]],
          [due_at: ~U[2026-11-09 09:00:00Z], state: :in_progress],
          [due_on: ~D[2026-11-02], state: :on_hold],
          [due_on: ~D[2026-11-10], state: :done],
          [due_on: ~D[2026-11-12]],
          []
        ] do
      task_fixture(hira, [team: c.backend, primary: c.fiza] ++ attrs)
    end

    task_fixture(fiza, team: c.backend, due_on: ~D[2026-11-10])
    task_fixture(hira, team: c.backend, primary: c.qasim, due_on: ~D[2026-11-10])

    where = %{"mine" => %{"$EQUAL" => true}, "due" => %{"$IN" => ["today", "overdue"]}}
    assert {:ok, page} = Board.page(fiza, %{"team_id" => c.backend.id, "$where" => where}, now)

    open =
      page.columns
      |> Enum.filter(&(&1.state in [:todo, :in_progress, :on_hold]))
      |> Enum.flat_map(& &1.items)

    assert {:ok, dashboard} = Me.build(fiza, %{"period" => "today"}, now)
    assert dashboard.tiles.tasks_due == 5
    assert length(open) == dashboard.tiles.tasks_due
  end
end
