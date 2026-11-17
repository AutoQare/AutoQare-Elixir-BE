defmodule Data.Filters.JobsSortTest do
  @moduledoc """
  `Data.Filters.JobsSort`: the three orders the pool's keyset pages, and
  nothing else.
  """

  use ExUnit.Case, async: true

  alias Data.Filters
  alias Data.Filters.JobsSort

  test "first_seen_at, posted_on and money, newest or highest first" do
    for field <- ~w(first_seen_at posted_on money) do
      assert Filters.order(JobsSort, %{field => "$desc"}) == {:ok, [{field, "$DESC"}]}
    end

    assert [{:desc, _first_seen}] = JobsSort.build(%{"first_seen_at" => "$DESC"})
    assert [{:desc_nulls_last, _posted}] = JobsSort.build(%{"posted_on" => "$DESC"})
  end

  test "a direction the keyset can't page, or another field, is refused" do
    assert {:error, {:invalid_filter, %{"first_seen_at" => _}}} =
             Filters.order(JobsSort, %{"first_seen_at" => "$ASC"})

    assert {:error, {:invalid_filter, %{"title" => _}}} =
             Filters.order(JobsSort, %{"title" => "$DESC"})
  end
end
