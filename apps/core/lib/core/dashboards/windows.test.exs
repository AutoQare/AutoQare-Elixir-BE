defmodule Core.Dashboards.WindowsTest do
  @moduledoc """
  The calendar windows (AQ-11 §4, QP11-3): built from dates in the
  organisation's zone, so a day a clock change makes 23 or 25 hours long
  is one day, and a midnight the change skips starts when the day does.
  Then the same through *My numbers* in a zone with summer time.
  """

  use Core.CoreCase, async: true

  alias Core.Dashboards
  alias Core.Dashboards.Windows

  doctest Core.Dashboards.Windows

  describe "pure" do
    test "London's spring day has 23 hours, its autumn day 25" do
      assert Windows.day(~D[2026-03-29], "Europe/London") ==
               {~U[2026-03-29 00:00:00.000000Z], ~U[2026-03-29 23:00:00.000000Z]}

      assert Windows.day(~D[2026-10-25], "Europe/London") ==
               {~U[2026-10-24 23:00:00.000000Z], ~U[2026-10-26 00:00:00.000000Z]}
    end

    test "a midnight the clock skips starts the day when it does (São Paulo, 4 Nov 2018)" do
      assert Windows.start_of(~D[2018-11-04], "America/Sao_Paulo") ==
               ~U[2018-11-04 03:00:00.000000Z]
    end

    test "the periods and cohorts are calendar spans" do
      now = ~U[2026-03-29 12:00:00Z]
      week = Windows.period(:week, now, "Europe/London")
      assert {week.first, week.last} == {~D[2026-03-23], ~D[2026-03-29]}

      assert {week.from, week.to} ==
               {~U[2026-03-23 00:00:00.000000Z], ~U[2026-03-29 23:00:00.000000Z]}

      month = Windows.period(:month, now, "Europe/London")
      assert {month.first, month.last} == {~D[2026-03-01], ~D[2026-03-31]}
      assert month.to == ~U[2026-03-31 23:00:00.000000Z]

      assert %{first: ~D[2025-12-30], last: ~D[2026-03-29]} =
               Windows.cohort(:last_90, now, "Europe/London")

      assert %{first: ~D[2026-02-01], last: ~D[2026-02-28]} =
               Windows.cohort(:last_month, now, "Europe/London")
    end

    test "keys from the query string" do
      assert Windows.period_key("month") == {:ok, :month}
      assert {:error, {:invalid, %{"period" => _}}} = Windows.period_key("year")
      assert Windows.cohort_key(nil) == {:ok, :this_month}
      assert {:error, {:invalid, %{"cohort" => _}}} = Windows.cohort_key("forever")
    end
  end

  describe "through My numbers, in London" do
    setup do
      c = board_cast_fixture()
      {:ok, org} = Data.Organisations.update(c.org, %{timezone: "Europe/London"})
      fs = scope_for(c.fiza)
      job = fn -> job_fixture(fs, team: c.backend) end
      Map.merge(c, %{org: org, fs: fs, job: job})
    end

    test "the long autumn Sunday: 23:30 GMT is still Sunday", c do
      apply_at(c.fs, c.job.(), c.golang, ~U[2026-10-25 23:30:00.000000Z])
      apply_at(c.fs, c.job.(), c.golang, ~U[2026-10-26 00:30:00.000000Z])

      {:ok, sunday} = Dashboards.me(c.fs, %{}, ~U[2026-10-25 23:45:00.000000Z])
      assert sunday.target.done_today == 1
      assert sunday.target.today == nil

      {:ok, monday} = Dashboards.me(c.fs, %{"period" => "week"}, ~U[2026-10-26 09:00:00.000000Z])
      assert {monday.target.done_today, monday.tiles.applications} == {1, 1}
      assert monday.target.today == 35
    end

    test "the short spring Monday: 00:30 BST on Monday is Sunday 23:30 UTC", c do
      apply_at(c.fs, c.job.(), c.golang, ~U[2026-03-29 22:30:00.000000Z])
      apply_at(c.fs, c.job.(), c.golang, ~U[2026-03-29 23:30:00.000000Z])

      {:ok, monday} = Dashboards.me(c.fs, %{"period" => "week"}, ~U[2026-03-30 09:00:00.000000Z])
      assert monday.period.from == ~D[2026-03-30]
      assert {monday.target.done_today, monday.tiles.applications} == {1, 1}
      assert [%{on: ~D[2026-03-30], done: 1}] = monday.target.run
    end
  end
end
