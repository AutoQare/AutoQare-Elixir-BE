defmodule Core.Leads.TrackerTest do
  @moduledoc """
  AQ-04B §8.1, §8.4, QP4b-15, QP4b-18: the Tracker — one team's leads by
  `peer_leads`, `$where` (`Data.Filters.Leads`: the board's filters plus
  `state`, `label` and `missing`), `$order` on any column, `group` with
  counts, keyset pages of 50 with the total — and its CSV (a BOM, every
  column, money as written, audited).
  """

  use Core.CoreCase, async: true

  alias Core.Dashboards.Windows
  alias Core.Leads.Tracker

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    bamboo = company_fixture(c.org, name: "Bamboo Invest")

    paid =
      job_fixture(fiza,
        team: c.backend,
        title: "Backend Developer",
        company: bamboo,
        comp_min_minor: 30_000_000,
        comp_max_minor: 40_000_000,
        comp_currency: "PKR",
        comp_period: :month
      )

    cv = document_fixture(c.golang, label: "Golang CV")
    naveed = profile_fixture(c.naveed, title: "Golang")

    applied =
      lead_fixture(fiza,
        job: paid,
        profile: c.golang,
        as: :apply,
        document_id: cv.id,
        last_activity_at: ~U[2026-11-10 09:00:00.000000Z]
      )

    saved =
      lead_fixture(scope_for(c.qasim),
        job: job_fixture(fiza, team: c.backend, title: "Another role"),
        profile: naveed,
        last_activity_at: ~U[2026-11-09 09:00:00.000000Z]
      )

    done =
      lead_fixture(fiza,
        job: job_fixture(fiza, team: c.backend, title: "Closed role"),
        profile: c.golang,
        state: :done,
        last_activity_at: ~U[2026-11-08 09:00:00.000000Z]
      )

    _elsewhere = lead_fixture(scope_for(c.hira), team: c.frontend)
    label = label_fixture(fiza, c.backend, name: "Priority client")
    Data.Labels.put_for_lead(applied.id, [label.id])

    Map.merge(c, %{applied: applied, saved: saved, done: done, label: label, cv: cv})
  end

  defp page(c, who, params \\ %{}),
    do: Tracker.page(scope_for(who), Map.put(params, "team_id", c.backend.id), @now)

  defp ids({:ok, %{items: items}}), do: Enum.map(items, & &1.id)

  test "every lead of the team, newest activity first, with the total and the row's shape", c do
    assert {:ok, %{items: [row | _] = items, total: 3, next_cursor: nil, groups: nil}} =
             page(c, c.hira)

    assert Enum.map(items, & &1.id) == [c.applied.id, c.saved.id, c.done.id]
    assert row.title == "Backend Developer" and row.company.name == "Bamboo Invest"
    assert row.labels == [%{id: c.label.id, name: "Priority client"}]
    assert row.cv == %{id: c.cv.id, label: "Golang CV", version: 1}
    assert row.missing == []
    assert row.money.currency == "PKR"
    assert %{archives_on: _, warn: false} = row.quiet
    assert row.owner.name == "Fiza"

    saved = Enum.find(items, &(&1.id == c.saved.id))
    assert saved.missing == ["money", "cv"]
  end

  defp where(c, who, where), do: page(c, who, %{"$where" => where})

  test "$where: state, label, missing, owner, customer, pipeline", c do
    assert ids(where(c, c.hira, %{"state" => %{"$EQUAL" => "in_progress"}})) == [c.applied.id]

    assert ids(where(c, c.hira, %{"state" => %{"$IN" => ["todo", "done"]}})) ==
             [c.saved.id, c.done.id]

    assert ids(where(c, c.hira, %{"label" => %{"$IN" => [c.label.id]}})) == [c.applied.id]
    assert ids(where(c, c.hira, %{"missing" => %{"$IN" => ["money"]}})) == [c.saved.id, c.done.id]
    assert ids(where(c, c.hira, %{"missing" => %{"$EQUAL" => "cv"}})) == [c.saved.id, c.done.id]
    assert ids(where(c, c.fiza, %{"owner" => %{"$EQUAL" => "me"}})) == [c.applied.id, c.done.id]
    assert ids(where(c, c.hira, %{"customer" => %{"$EQUAL" => c.naveed.id}})) == [c.saved.id]
    assert {:ok, %{total: 3}} = where(c, c.hira, %{"pipeline" => %{"$EQUAL" => "employment"}})
    assert {:ok, %{total: 0}} = where(c, c.hira, %{"pipeline" => %{"$EQUAL" => "freelance"}})

    assert {:error, {:invalid_filter, %{"missing" => _}}} =
             where(c, c.hira, %{"missing" => %{"$IN" => ["recruiter"]}})

    other = label_fixture(scope_for(c.hira), c.frontend)

    assert {:error, {:invalid_filter, %{"label" => _}}} =
             where(c, c.hira, %{"label" => %{"$IN" => [other.id]}})

    assert {:error, {:invalid_filter, %{"follow_up" => _}}} =
             where(c, c.hira, %{"$OR" => [%{"follow_up" => %{"$EQUAL" => "due"}}]})
  end

  defp order(c, column, dir), do: page(c, c.hira, %{"$order" => %{column => dir}})

  test "$order on any column, either way; nothing sorts last", c do
    assert ids(order(c, "title", "$ASC")) == [c.saved.id, c.applied.id, c.done.id]
    assert ids(order(c, "title", "$DESC")) == [c.done.id, c.applied.id, c.saved.id]
    assert ids(order(c, "applied", "$ASC")) |> hd() == c.applied.id
    # The lead never applied for sorts last, whichever way.
    assert ids(order(c, "applied", "$ASC")) |> List.last() == c.saved.id
    assert ids(order(c, "applied", "$DESC")) |> List.last() == c.saved.id
    assert ids(order(c, "money", "$DESC")) |> hd() == c.applied.id
    assert ids(order(c, "money", "$ASC")) |> hd() == c.applied.id
    assert ids(order(c, "labels", "$ASC")) |> hd() == c.applied.id
    assert ids(order(c, "state", "$ASC")) == [c.saved.id, c.applied.id, c.done.id]
    assert ids(order(c, "state", "$DESC")) == [c.done.id, c.applied.id, c.saved.id]
    assert ids(order(c, "cv", "$DESC")) |> hd() == c.applied.id
    assert ids(order(c, "last_activity", "$ASC")) == [c.done.id, c.saved.id, c.applied.id]

    for column <- Data.Vocabulary.tracker_columns(),
        dir <- ["$ASC", "$DESC"],
        do: assert({:ok, %{total: 3}} = order(c, column, dir))

    assert {:error, {:invalid_filter, %{"nope" => _}}} = order(c, "nope", "$ASC")
    assert {:error, {:invalid_filter, %{"title" => _}}} = order(c, "title", "up")

    assert {:error, {:invalid_filter, %{"$order" => _}}} =
             page(c, c.hira, %{"$order" => %{"title" => "$ASC", "cv" => "$ASC"}})
  end

  test "P11's tile filters open what My numbers counts (AQ-11B §11.4)", c do
    fs = scope_for(c.fiza)
    zone = Core.Dashboards.zone(fs)
    today = Utils.Days.today(@now, zone)
    hour = fn h -> DateTime.add(Utils.Days.start_of(today, zone), h * 3600, :second) end

    event = fn lead, kind, at, attrs ->
      {:ok, _event} =
        Data.Leads.add_event(
          Map.merge(
            %{
              organisation_id: c.org.id,
              lead_id: lead.id,
              kind: kind,
              occurred_at: at,
              recorded_at: at,
              actor_kind: :user,
              actor_user_id: c.fiza.id,
              visibility: :customer
            },
            attrs
          )
        )
    end

    # Today: Fiza applies twice and hears back once; Qasim applies once.
    # Five days ago: Fiza's application now owes a follow-up.
    quiet = lead_fixture(fs, team: c.backend, profile: c.golang, as: :apply)
    second = lead_fixture(fs, team: c.backend, profile: c.golang, as: :apply)
    event.(c.applied, :applied, hour.(1), %{stage_kind: :applied})
    event.(c.applied, :stage_moved, hour.(2), %{stage_kind: :screening})
    event.(second, :applied, hour.(3), %{stage_kind: :applied})
    event.(c.saved, :applied, hour.(4), %{stage_kind: :applied, actor_user_id: c.qasim.id})
    event.(quiet, :applied, DateTime.add(@now, -5 * 86_400, :second), %{stage_kind: :applied})

    {:ok, me} = Core.Dashboards.me(fs, %{"period" => "today"}, @now)

    count = fn where ->
      {:ok, %{total: n}} = page(c, c.fiza, %{"$where" => where})
      n
    end

    applications = %{
      "applied_on" => %{"$BETWEEN" => [Date.to_iso8601(today), Date.to_iso8601(today)]},
      "applied_by" => %{"$EQUAL" => "me"}
    }

    assert me.tiles.applications == 2
    assert count.(applications) == me.tiles.applications

    assert me.tiles.responses.count == 1

    assert count.(Map.put(applications, "had_response", %{"$EQUAL" => true})) ==
             me.tiles.responses.count

    follow_ups = %{"follow_up" => %{"$EQUAL" => "due"}, "owner" => %{"$EQUAL" => "me"}}
    assert me.tiles.follow_ups_due == 1
    assert count.(follow_ups) == me.tiles.follow_ups_due
    assert {:ok, %{items: [%{id: id}]}} = page(c, c.fiza, %{"$where" => follow_ups})
    assert id == quiet.id
  end

  test "each of My numbers' lead tiles equals the list its link opens, for a day and a week", c do
    fs = scope_for(c.fiza)
    zone = Core.Dashboards.zone(fs)
    today = Utils.Days.today(@now, zone)

    at = fn days, h ->
      DateTime.add(Utils.Days.start_of(Date.add(today, days), zone), h * 3600)
    end

    iso = &Date.to_iso8601/1

    event = fn lead, kind, when_at, attrs ->
      {:ok, _event} =
        Data.Leads.add_event(
          Map.merge(
            %{
              organisation_id: c.org.id,
              lead_id: lead.id,
              kind: kind,
              occurred_at: when_at,
              recorded_at: when_at,
              actor_kind: :user,
              actor_user_id: c.fiza.id,
              visibility: :customer
            },
            attrs
          )
        )
    end

    lead = fn -> lead_fixture(fs, team: c.backend, profile: c.golang, as: :apply) end
    [staged, met, proposed, earlier, shelved, replied] = for _n <- 1..6, do: lead.()

    # Interviews: a stage of an interview kind reached today; a technical
    # meeting today; a cancelled one and a screening call (not counted); one three days ago (the
    # week's, not today's); an archived lead's today (counted, as the tile does).
    event.(staged, :stage_moved, at.(0, 2), %{stage_kind: :interview})
    meeting_fixture(fs, lead: met, starts_at: at.(0, 3))
    meeting_fixture(fs, lead: proposed, starts_at: at.(0, 4), status: :cancelled)
    meeting_fixture(fs, lead: proposed, starts_at: at.(0, 5), meeting_kind: :screening)
    event.(earlier, :stage_moved, at.(-3, 2), %{stage_kind: :final})
    event.(shelved, :stage_moved, at.(0, 6), %{stage_kind: :assessment})

    # Applications and responses: today and earlier in the week, one answered.
    event.(replied, :applied, at.(0, 1), %{stage_kind: :applied})
    event.(replied, :stage_moved, at.(0, 2), %{stage_kind: :screening})
    event.(staged, :applied, at.(-2, 1), %{stage_kind: :applied})
    event.(met, :applied, at.(0, 1), %{stage_kind: :applied})

    {:ok, _archived} =
      shelved
      |> Ecto.Changeset.change(archived_at: at.(0, 7), archive_reason: :by_hand)
      |> Data.Repo.update()

    week = Windows.period(:week, @now, zone)
    days = %{"today" => {today, today}, "week" => {week.first, week.last}}

    for {period, {first, last}} <- days do
      {:ok, me} = Core.Dashboards.me(fs, %{"period" => period}, @now)
      both = %{"archived" => %{"$IN" => [true, false]}}
      range = %{"$BETWEEN" => [iso.(first), iso.(last)]}

      count = fn where ->
        {:ok, %{total: n, items: items}} = page(c, c.fiza, %{"$where" => Map.merge(both, where)})
        assert length(items) == min(n, 50)
        n
      end

      applications = %{"applied_on" => range, "applied_by" => %{"$EQUAL" => "me"}}
      assert count.(applications) == me.tiles.applications, period

      assert count.(Map.put(applications, "had_response", %{"$EQUAL" => true})) ==
               me.tiles.responses.count,
             period

      interviews = %{"interviewed_on" => range, "owner" => %{"$EQUAL" => "me"}}
      assert count.(interviews) == me.tiles.interviews, period

      follow_ups = %{"follow_up" => %{"$EQUAL" => "due"}, "owner" => %{"$EQUAL" => "me"}}
      assert count.(follow_ups) == me.tiles.follow_ups_due, period
    end

    {:ok, today_numbers} = Core.Dashboards.me(fs, %{"period" => "today"}, @now)
    assert today_numbers.tiles.interviews == 3
    assert today_numbers.tiles.responses.count == 1

    one_day = %{"interviewed_on" => %{"$EQUAL" => iso.(today)}}

    assert {:ok, %{total: 2}} = page(c, c.fiza, %{"$where" => one_day})

    assert {:error, {:invalid_filter, %{"interviewed_on" => _}}} =
             page(c, c.fiza, %{"$where" => %{"interviewed_on" => %{"$BETWEEN" => ["x", "y"]}}})
  end

  test "applications beside leads: a lead applied twice is one lead, two applications (AQ-11B §11.5)",
       c do
    fs = scope_for(c.fiza)
    zone = Core.Dashboards.zone(fs)
    today = Utils.Days.today(@now, zone)

    at = fn days, h ->
      DateTime.add(Utils.Days.start_of(Date.add(today, days), zone), h * 3600)
    end

    iso = &Date.to_iso8601/1

    event = fn lead, kind, when_at, attrs ->
      {:ok, _event} =
        Data.Leads.add_event(
          Map.merge(
            %{
              organisation_id: c.org.id,
              lead_id: lead.id,
              kind: kind,
              occurred_at: when_at,
              recorded_at: when_at,
              actor_kind: :user,
              actor_user_id: c.fiza.id,
              visibility: :customer
            },
            attrs
          )
        )
    end

    # Today Fiza applies on eight leads, on the first one twice; the first
    # hears back after both, the second after its one. Earlier this week she
    # applied on a ninth; Qasim's application today is his.
    [twice, answered | _rest] =
      leads = for _n <- 1..8, do: lead_fixture(fs, team: c.backend, profile: c.golang, as: :apply)

    for lead <- leads, do: event.(lead, :applied, at.(0, 1), %{stage_kind: :applied})
    event.(twice, :applied, at.(0, 3), %{stage_kind: :applied})
    event.(answered, :stage_moved, at.(0, 2), %{stage_kind: :screening})
    event.(twice, :stage_moved, at.(0, 4), %{stage_kind: :screening})
    monday = lead_fixture(fs, team: c.backend, profile: c.golang, as: :apply)
    event.(monday, :applied, at.(-2, 1), %{stage_kind: :applied})
    event.(c.saved, :applied, at.(0, 1), %{stage_kind: :applied, actor_user_id: c.qasim.id})

    head = fn first, last, extra ->
      where =
        Map.merge(
          %{
            "applied_on" => %{"$BETWEEN" => [iso.(first), iso.(last)]},
            "applied_by" => %{"$EQUAL" => "me"},
            "archived" => %{"$IN" => [true, false]}
          },
          extra
        )

      {:ok, %{total: total, applications: applications}} = page(c, c.fiza, %{"$where" => where})
      {total, applications}
    end

    {:ok, day} = Core.Dashboards.me(fs, %{"period" => "today"}, @now)
    assert head.(today, today, %{}) == {8, 9}
    assert day.tiles.applications == 9

    responded = %{"had_response" => %{"$EQUAL" => true}}
    assert head.(today, today, responded) == {2, 3}
    assert day.tiles.responses.count == 3

    week = Windows.period(:week, @now, zone)
    {:ok, this_week} = Core.Dashboards.me(fs, %{"period" => "week"}, @now)
    assert head.(week.first, week.last, %{}) == {9, 10}
    assert this_week.tiles.applications == 10
    assert elem(head.(week.first, week.last, responded), 1) == this_week.tiles.responses.count

    # Every other filter narrows the count with the leads: one lead, two applications.
    assert head.(today, today, %{"$OR" => [%{"profile" => c.golang.id}]}) == {8, 9}
    assert {1, 2} = head.(today, today, %{"label" => %{"$IN" => [label_on(c, twice)]}})

    # One part alone counts too; without any, there is nothing to count.
    assert {:ok, %{applications: 10}} =
             page(c, c.fiza, %{"$where" => %{"applied_by" => %{"$EQUAL" => "me"}}})

    assert {:ok, %{applications: nil}} =
             page(c, c.fiza, %{"$where" => %{"owner" => %{"$EQUAL" => "me"}}})

    assert {:ok, %{applications: nil}} = page(c, c.fiza)
  end

  defp label_on(c, lead) do
    label = label_fixture(scope_for(c.fiza), c.backend)
    Data.Labels.put_for_lead(lead.id, [label.id])
    label.id
  end

  test "group by state: rows run group by group, with the counts", c do
    assert {:ok, %{items: items, groups: groups}} = page(c, c.hira, %{"group" => "state"})
    assert Enum.map(items, & &1.state) == [:todo, :in_progress, :done]

    assert groups == [
             %{key: "todo", name: "To do", count: 1},
             %{key: "in_progress", name: "In progress", count: 1},
             %{key: "done", name: "Done", count: 1}
           ]

    assert {:ok, %{groups: [_, _]}} = page(c, c.hira, %{"group" => "customer"})
    assert {:ok, %{groups: groups}} = page(c, c.hira, %{"group" => "stage"})
    assert Enum.map(groups, & &1.name) == ["To do", "In progress · Applied", "Done · Applied"]
  end

  test "a member at hidden sees their own; another team's member finds nothing", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    assert ids(page(c, c.qasim)) == [c.saved.id]
    assert ids(page(c, c.muaz)) == []

    farah = member_fixture(c.frontend, :member, user_fixture())
    assert page(c, farah) == {:error, :not_found}

    assert Tracker.page(scope_for(c.hira), %{}, @now) ==
             {:error, {:invalid, %{"team_id" => ["is required"]}}}
  end

  test "keyset pages of 50 with the total; More continues after the last row", c do
    for _ <- 1..50,
        do:
          lead_fixture(scope_for(c.fiza),
            team: c.backend,
            last_activity_at: ~U[2026-11-01 09:00:00.000000Z]
          )

    {:ok, %{items: first, total: 53, next_cursor: cursor}} = page(c, c.hira)
    assert length(first) == 50 and is_binary(cursor)

    {:ok, %{items: rest, next_cursor: nil}} = page(c, c.hira, %{"cursor" => cursor})
    assert length(rest) == 3
    assert MapSet.disjoint?(MapSet.new(first, & &1.id), MapSet.new(rest, & &1.id))
  end

  test "the CSV: a BOM, every column, money as written, audited", c do
    assert {:ok, body, filename} =
             Tracker.csv(
               scope_for(c.hira),
               %{"team_id" => c.backend.id, "$order" => %{"title" => "$ASC"}},
               @now
             )

    csv = IO.iodata_to_binary(body)
    assert String.starts_with?(csv, "﻿Applied,Title,Company,Source,Customer,Profile,Owner,")
    assert filename == "tracker-backend-squad-2026-11-11.csv"

    [_header | rows] = csv |> String.trim_trailing() |> String.split("\r\n")
    assert length(rows) == 3
    paid = Enum.find(rows, &String.contains?(&1, "Backend Developer"))
    assert paid =~ "PKR 300,000–400,000 / month"
    assert paid =~ "Priority client"
    assert paid =~ "In progress · Applied"
    # Source, workplace and engagement read as words, never as the vocabulary's keys.
    for row <- rows, do: refute(row =~ ~r/\b(company_site|on_site|full_time|part_time|yc_waas)\b/)

    [audit] =
      Data.Audit.list_for_subject(c.org.id, "teams", c.backend.id)
      |> Enum.filter(&(&1.action == "tracker_exported"))

    assert audit.after["rows"] == 3
    assert audit.after["query"] == "%24order[title]=%24ASC"
  end
end
