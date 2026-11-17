defmodule Data.Filters.TasksTest do
  @moduledoc """
  `Data.Filters.Tasks` and `TasksSort`: each field and operator, each
  override against a direct query (the due days in the organisation's
  zone), the refusals, and the board's order with its ties.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Tasks.{Participant, Step, Task}

  # 00:30 in Karachi (UTC+5): the local day is the 11th while UTC's is the 10th.
  @now ~U[2026-11-10 19:30:00.000000Z]
  @zone "Asia/Karachi"

  setup do
    c = board_cast_fixture()
    hira = scope_for(c.hira)
    fiza = scope_for(c.fiza)
    {:ok, stage} = Data.TaskStages.create(c.fiza.id, "Sourcing")

    t = %{
      urgent:
        task_fixture(hira,
          team: c.backend,
          priority: :urgent,
          title: "Apply to Bamboo",
          due_on: ~D[2026-11-11],
          customer: c.tanweer,
          profile: c.golang,
          primary: c.fiza
        ),
      late:
        task_fixture(hira,
          team: c.backend,
          priority: :low,
          title: "Call Omar",
          due_at: ~U[2026-11-10 10:00:00Z]
        ),
      tonight:
        task_fixture(hira,
          team: c.backend,
          priority: :high,
          title: "Send CV",
          due_at: ~U[2026-11-10 19:30:00Z],
          primary: c.qasim,
          watchers: [c.fiza]
        ),
      week: task_fixture(hira, team: c.backend, title: "Shortlist", due_on: ~D[2026-11-16]),
      later: task_fixture(hira, team: c.backend, title: "Plan", due_on: ~D[2026-11-30]),
      done:
        task_fixture(hira,
          team: c.backend,
          title: "Old call",
          due_at: ~U[2026-11-09 09:00:00Z],
          state: :done
        ),
      own: task_fixture(fiza, team: c.backend, title: "Read the brief"),
      draft: task_fixture(fiza, team: c.backend, title: "Idea", state: :draft),
      given: task_fixture(fiza, team: c.backend, title: "Handed on", primary: c.qasim)
    }

    stepped = task_fixture(hira, team: c.backend, title: "Stepped", primary: c.hira)
    step_fixture(stepped, assignee: c.fiza)
    {:ok, staged} = Data.Tasks.move(t.later, %{state: :in_progress, stage_id: stage.id})
    archived = task_fixture(hira, team: c.backend, title: "Archived plan")
    Repo.update_all(from(x in Task, where: x.id == ^archived.id), set: [archived_at: @now])

    t = Map.merge(t, %{stepped: stepped, later: staged, archived: archived})
    ctx = %{user_id: c.fiza.id, now: @now, zone: @zone}
    Map.merge(c, %{t: t, ctx: ctx, stage: stage})
  end

  defp ids(c, where) do
    base = from(x in Task, where: x.organisation_id == ^c.org.id)
    {:ok, query} = Filters.where(base, Filters.Tasks, where, c.ctx)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(c, condition) do
    from(x in Task, where: x.organisation_id == ^c.org.id)
    |> where(^condition)
    |> Repo.all()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp sorted(list), do: list |> Enum.map(& &1.id) |> Enum.sort()

  test "mine: assigned, my open steps, my drafts and my own nobody is on — never what I handed on",
       c do
    me = c.fiza.id

    assigned =
      from(p in Participant, where: p.user_id == ^me and not is_nil(p.level), select: p.task_id)

    steps =
      from(s in Step, where: s.assignee_user_id == ^me and is_nil(s.done_at), select: s.task_id)

    owned = from(p in Participant, where: not is_nil(p.level), select: p.task_id)

    expected =
      direct(
        c,
        dynamic(
          [x],
          x.id in subquery(assigned) or x.id in subquery(steps) or
            (x.author_user_id == ^me and (x.state == :draft or x.id not in subquery(owned)))
        )
      )

    assert ids(c, %{"mine" => %{"$EQUAL" => "true"}}) == expected
    assert expected == sorted([c.t.urgent, c.t.own, c.t.draft, c.t.stepped])
    refute c.t.given.id in expected
    assert ids(c, %{"mine" => %{"$EQUAL" => false}}) == ids(c, %{})
  end

  test "watching, customer_id, profile_id, stage_id, people, no_owner", c do
    assert ids(c, %{"watching" => %{"$EQUAL" => true}}) == [c.t.tonight.id]
    assert ids(c, %{"customer_id" => %{"$EQUAL" => c.tanweer.id}}) == [c.t.urgent.id]
    assert ids(c, %{"profile_id" => %{"$IN" => [c.golang.id]}}) == [c.t.urgent.id]
    assert ids(c, %{"stage_id" => %{"$EQUAL" => c.stage.id}}) == [c.t.later.id]

    assert ids(c, %{"people" => %{"$IN" => [c.fiza.id, c.qasim.id]}}) ==
             sorted([c.t.urgent, c.t.tonight, c.t.given])

    assert ids(c, %{"people" => %{"$EQUAL" => c.hira.id}}) == [c.t.stepped.id]

    owned = from(p in Participant, where: not is_nil(p.level), select: p.task_id)

    assert ids(c, %{"no_owner" => %{"$EQUAL" => true}}) ==
             direct(c, dynamic([x], x.id not in subquery(owned)))
  end

  test "archived and q", c do
    assert ids(c, %{"archived" => %{"$EQUAL" => true}}) == [c.t.archived.id]
    refute c.t.archived.id in ids(c, %{"archived" => %{"$EQUAL" => "false"}})
    assert ids(c, %{"q" => %{"$ILIKE" => "%CALL%"}}) == sorted([c.t.late, c.t.done])
    assert ids(c, %{"q" => %{"$ILIKE" => "omar"}}) == [c.t.late.id]
  end

  test "priority: normal is none; $EQUAL and $IN", c do
    assert ids(c, %{"priority" => %{"$EQUAL" => "urgent"}}) == [c.t.urgent.id]

    assert ids(c, %{"priority" => %{"$IN" => ["low", "high"]}}) ==
             sorted([c.t.late, c.t.tonight])

    assert ids(c, %{"priority" => %{"$IN" => ["normal"]}}) ==
             direct(c, dynamic([x], is_nil(x.priority)))
  end

  test "due, in the organisation's zone: today, overdue, week, none — each as a direct query",
       c do
    # Karachi's 11 Nov runs 2026-11-10 19:00Z to 2026-11-11 19:00Z.
    {from, to} = {~U[2026-11-10 19:00:00.000000Z], ~U[2026-11-11 19:00:00.000000Z]}

    today =
      direct(
        c,
        dynamic(
          [x],
          x.due_on == ^~D[2026-11-11] or (x.due_at >= ^from and x.due_at < ^to)
        )
      )

    assert ids(c, %{"due" => %{"$EQUAL" => "today"}}) == today
    assert today == sorted([c.t.urgent, c.t.tonight])

    overdue =
      direct(
        c,
        dynamic(
          [x],
          x.state in [:todo, :in_progress, :on_hold] and
            (x.due_at < ^@now or x.due_on < ^~D[2026-11-11])
        )
      )

    assert ids(c, %{"due" => %{"$EQUAL" => "overdue"}}) == overdue
    assert overdue == [c.t.late.id]

    week_end = ~U[2026-11-17 19:00:00.000000Z]

    week =
      direct(
        c,
        dynamic(
          [x],
          (x.due_on >= ^~D[2026-11-11] and x.due_on <= ^~D[2026-11-17]) or
            (x.due_at >= ^from and x.due_at < ^week_end)
        )
      )

    assert ids(c, %{"due" => %{"$EQUAL" => "week"}}) == week
    assert week == sorted([c.t.urgent, c.t.tonight, c.t.week])

    assert ids(c, %{"due" => %{"$EQUAL" => "none"}}) ==
             direct(c, dynamic([x], is_nil(x.due_at) and is_nil(x.due_on)))

    assert ids(c, %{"due" => %{"$IN" => ["today", "overdue"]}}) ==
             Enum.sort(today ++ overdue)
  end

  test "what the list doesn't take is refused, naming the field", c do
    base = from(x in Task, where: x.organisation_id == ^c.org.id)

    for {where, field} <- [
          {%{"title" => "Plan"}, "title"},
          {%{"state" => %{"$EQUAL" => "todo"}}, "state"},
          {%{"due" => %{"$EQUAL" => "someday"}}, "due"},
          {%{"due" => %{"$GT" => "today"}}, "due"},
          {%{"priority" => %{"$IN" => ["huge"]}}, "priority"},
          {%{"mine" => %{"$EQUAL" => "yes"}}, "mine"},
          {%{"people" => %{"$IN" => ["not-an-id"]}}, "people"},
          {%{"customer_id" => %{"$IN" => [c.tanweer.id]}}, "customer_id"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Tasks, where, c.ctx)
    end
  end

  describe "the board's order (TasksSort) with its ties" do
    setup c do
      filter = %{
        organisation_id: c.org.id,
        user_id: c.hira.id,
        admin?: true,
        lead_team_ids: [],
        peer_team_ids: []
      }

      %{filter: filter}
    end

    defp board(c, where, order) do
      {:ok, tasks} = Data.Tasks.board(c.filter, c.backend.id, where, order, c.ctx)
      Enum.map(tasks, & &1.id)
    end

    test "due (the default): soonest first, a day at its end, none last; then the oldest", c do
      shown = board(c, %{"q" => %{"$ILIKE" => "a"}}, nil)
      due = board(c, %{"q" => %{"$ILIKE" => "a"}}, %{"due" => "$ASC"})
      assert shown == due

      assert Enum.take(board(c, %{"due" => %{"$IN" => ["today", "overdue"]}}, nil), 2) ==
               [c.t.late.id, c.t.tonight.id]

      assert List.last(board(c, %{}, nil)) in [c.t.own.id, c.t.given.id, c.t.stepped.id]
    end

    test "priority: urgent, high, normal, low", c do
      order = board(c, %{"priority" => %{"$IN" => ~w(urgent high low)}}, %{"priority" => "$ASC"})
      assert order == [c.t.urgent.id, c.t.tonight.id, c.t.late.id]
    end

    test "inserted_at: the newest first; only the live unless archived is asked", c do
      newest = board(c, %{}, %{"inserted_at" => "$DESC"})
      assert hd(newest) == c.t.stepped.id
      refute c.t.archived.id in newest
      assert board(c, %{"archived" => true}, nil) == [c.t.archived.id]
    end

    test "an order the board doesn't take is refused", c do
      for order <- [%{"title" => "$ASC"}, %{"due" => "$DESC"}, %{"inserted_at" => "$ASC"}] do
        assert {:error, {:invalid_filter, _}} =
                 Data.Tasks.board(c.filter, c.backend.id, nil, order, c.ctx)
      end
    end
  end
end
