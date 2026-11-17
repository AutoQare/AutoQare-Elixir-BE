defmodule Data.JobList do
  @moduledoc """
  A team's pool (AQ-03 §7.1, AQ-03B §3.1) as a query: the scoped base
  query, the list's `$where` through `Data.Filters.Jobs`, and the three
  sorts by keyset (`Data.Filters.JobsSort`). Who of the team sees which job
  is the caller's `visible_to`: `:all`, or `{user_id, peers?}` — their own
  jobs, and the team's others too when `peers?` (the team's `peer_jobs` is
  not hidden). `Core.Jobs.Pool` reads the parameters and owns the cursor's
  encoding; this module only composes SQL.

  The money key is `Utils.Units`' factors written as SQL
  (`Data.Filters.Jobs.annual_top/0`); `Data.JobListTest` holds the two to
  the same numbers.
  """

  import Ecto.Query, warn: false

  alias Data.Filters
  alias Data.Filters.JobsSort
  alias Data.Jobs
  alias Data.Jobs.Job
  alias Data.Repo

  @doc """
  The team's jobs `visible_to` the caller, narrowed by `where` (the list's
  `$where`, `archived {$EQUAL: false}` unless sent) with `context` (the
  map `Data.Filters.context/2` makes): `{:ok, query}`, or the 422
  `invalid_filter`.
  """
  @spec matching(binary(), :all | {binary(), boolean()}, term(), map()) ::
          {:ok, Ecto.Query.t()} | {:error, term()}
  def matching(team_id, visible_to, where, context \\ %{}) do
    base =
      from(j in Job, as: :job, where: j.team_id == ^team_id)
      |> visible(visible_to)

    where = Filters.default(where, "archived", %{"$EQUAL" => false})
    Filters.where(base, Filters.Jobs, where, context)
  end

  @doc """
  One page of `query`: at most `limit` jobs after `cursor` (the sort key
  and id of the last row seen), plus one more when there is a next page.
  `sort` is `:newest`, `:posted` or `:money` (which needs `money_sort`, a
  `%{currency, project?}`).
  """
  @spec page(Ecto.Query.t(), atom(), map() | nil, term(), pos_integer()) :: [Job.t()]
  def page(query, sort, money_sort, cursor, limit) do
    query
    |> sorted(sort, money_sort)
    |> after_cursor(sort, money_sort, cursor)
    |> limit(^(limit + 1))
    |> preload(^Jobs.base_preload())
    |> Repo.all()
  end

  @doc "Every job of `query`, unsorted: the candidates `suggested_for` scores."
  @spec all(Ecto.Query.t()) :: [Job.t()]
  def all(query), do: query |> preload(^Jobs.base_preload()) |> Repo.all()

  @doc """
  Every job of the team matching `where` (`archived {$EQUAL: false}` unless
  sent), unsorted, for a reader other than the list (the portal's
  suggestions): `{:ok, jobs}` or the 422.
  """
  @spec all(binary(), term()) :: {:ok, [Job.t()]} | {:error, term()}
  def all(team_id, where) do
    with {:ok, query} <- matching(team_id, :all, where), do: {:ok, all(query)}
  end

  @doc "The money sort's key for one job, as the SQL computes it."
  @spec money_key(Job.t(), map()) :: integer() | nil
  def money_key(%Job{comp_currency: currency} = job, %{currency: currency, project?: project?}) do
    top = job.comp_max_minor || job.comp_min_minor

    cond do
      project? and job.comp_period == :project -> top
      project? -> nil
      true -> Utils.Units.annualise(top, job.comp_period)
    end
  end

  def money_key(_job, _sort), do: nil

  defp visible(query, {_me, true}), do: query
  defp visible(query, {me, false}), do: where(query, [j], j.created_by_user_id == ^me)
  defp visible(query, :all), do: query

  defp money_sort_key(%{currency: currency, project?: true}) do
    dynamic(
      [j],
      fragment(
        "CASE WHEN ? = ? AND ? = 'project' THEN ? END",
        j.comp_currency,
        ^currency,
        j.comp_period,
        coalesce(j.comp_max_minor, j.comp_min_minor)
      )
    )
  end

  defp money_sort_key(%{currency: currency}) do
    dynamic(
      [j],
      fragment(
        "CASE WHEN ? = ? THEN ? END",
        j.comp_currency,
        ^currency,
        ^Filters.Jobs.annual_top()
      )
    )
  end

  # ── Sorts and the keyset ────────────────────────────────────────────────────

  defp sorted(query, :newest, _money_sort),
    do: order_by(query, ^(JobsSort.build(%{"first_seen_at" => "$DESC"}) ++ [desc: :id]))

  defp sorted(query, :posted, _money_sort),
    do: order_by(query, ^(JobsSort.build(%{"posted_on" => "$DESC"}) ++ [desc: :id]))

  defp sorted(query, :money, money_sort) do
    key = money_sort_key(money_sort)
    order_by(query, ^[desc_nulls_last: key, desc: dynamic([j], j.id)])
  end

  defp after_cursor(query, _sort, _money_sort, nil), do: query

  defp after_cursor(query, :newest, _money_sort, {%DateTime{} = at, id}) do
    where(query, [j], j.first_seen_at < ^at or (j.first_seen_at == ^at and j.id < ^id))
  end

  defp after_cursor(query, :posted, _money_sort, {on, id}),
    do: where(query, ^nullable_after(dynamic([j], j.posted_on), on, id))

  defp after_cursor(query, :money, money_sort, {value, id}),
    do: where(query, ^nullable_after(money_sort_key(money_sort), value, id))

  # Descending with nulls last: after a value come smaller values, the same
  # value with a smaller id, then every null; after a null, nulls with a
  # smaller id.
  defp nullable_after(key, nil, id), do: dynamic([j], is_nil(^key) and j.id < ^id)

  defp nullable_after(key, value, id) do
    dynamic([j], ^key < ^value or (^key == ^value and j.id < ^id) or is_nil(^key))
  end
end
