defmodule Data.Filters.TrackerSortTest do
  @moduledoc """
  `Data.Filters.TrackerSort` through `Data.Leads.for_team/4`: every column
  both ways checked and built (the three computed on read build nothing),
  nothing sorting last either way, ties by id, and the 422.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Filters.TrackerSort
  alias Data.Leads

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    usd = fn amount -> [comp_min_minor: amount, comp_currency: "USD", comp_period: :year] end

    low =
      lead_fixture(fs,
        job: job_fixture(fs, [team: c.backend, title: "beta"] ++ usd.(100)),
        profile: c.golang
      )

    high =
      lead_fixture(fs,
        job: job_fixture(fs, [team: c.backend, title: "Alpha"] ++ usd.(900)),
        profile: c.golang
      )

    none =
      lead_fixture(fs, job: job_fixture(fs, team: c.backend, title: "gamma"), profile: c.golang)

    Map.merge(c, %{low: low, high: high, none: none})
  end

  defp sorted(c, column, dir) do
    {:ok, [{^column, dir}]} = Filters.order(TrackerSort, %{column => dir})
    order = TrackerSort.build(%{column => dir})
    {:ok, leads} = Leads.for_team(c.backend.id, nil, %{}, order: order)
    Enum.map(leads, & &1.id)
  end

  test "every column both ways is checked; the computed ones build nothing" do
    for column <- Data.Vocabulary.tracker_columns(), dir <- ["$ASC", "$DESC"] do
      assert {:ok, [{^column, ^dir}]} = Filters.order(TrackerSort, %{column => dir})
      built = TrackerSort.build(%{column => dir})

      if column in TrackerSort.in_memory(),
        do: assert(built == []),
        else: assert([{_nulls_last, %Ecto.Query.DynamicExpr{}}] = built)
    end
  end

  test "every SQL column runs either way", c do
    for column <- Data.Vocabulary.tracker_columns() -- TrackerSort.in_memory(),
        dir <- ["$ASC", "$DESC"],
        do: assert(length(sorted(c, column, dir)) == 3)
  end

  test "title lower-cased; money by amount; nothing sorts last either way", c do
    assert sorted(c, "title", "$ASC") == [c.high.id, c.low.id, c.none.id]
    assert sorted(c, "title", "$DESC") == [c.none.id, c.low.id, c.high.id]
    assert sorted(c, "money", "$ASC") == [c.low.id, c.high.id, c.none.id]
    assert sorted(c, "money", "$DESC") == [c.high.id, c.low.id, c.none.id]
  end

  test "ties go by id", c do
    ids = Enum.sort([c.low.id, c.high.id, c.none.id])
    assert sorted(c, "source", "$ASC") == ids
    assert sorted(c, "source", "$DESC") == ids
  end

  test "an unlisted column or direction is refused" do
    assert {:error, {:invalid_filter, %{"colour" => _}}} =
             Filters.order(TrackerSort, %{"colour" => "$ASC"})

    assert {:error, {:invalid_filter, %{"title" => _}}} =
             Filters.order(TrackerSort, %{"title" => "$UP"})
  end
end
