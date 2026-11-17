defmodule Core.Jobs.Pool do
  @moduledoc """
  `GET /jobs?team_id&$where&$order&currency&cursor` (AQ-03 §7.1, AQ-03B
  §5.1, AQ-11B §11.4): **one team's pool**, a keyset page of 50 rows and an
  opaque cursor. `team_id` is required (422 without it; 404 for a team the
  caller is not in, unless an admin); a member whose team's `peer_jobs` is
  `hidden` lists only their own jobs.

  | Parameter | Rule |
  |---|---|
  | `team_id` | required: the team whose pool this is |
  | `$where` | `Data.Filters.Jobs`' fields (`source` · `engagement` · `workplace` · `remote_scope` · `status`, `q`, `country`, `skills`, `money`, `posted_within`, `archived`, `has_leads`, `not_applied_with`, `suggested_for`); a field, operator or value it doesn't take is the 422 `invalid_filter` |
  | `$order` | `Data.Filters.JobsSort`' one field: `first_seen_at` (the default) · `posted_on` · `money`, each `$DESC`; ties by id |
  | `currency` | the money sort's currency when no money filter names one (a switch, not a filter: other currencies sort last) |
  | `cursor` | the last page's `next_cursor` |

  **`suggested_for` stays in memory**: the jobs the rest of `$where`
  matches are scored on read (`Core.Jobs.Suggest`), those at 70 and above
  for the profile and not dismissed kept, best first — the score has no
  SQL form. `not_applied_with` and `suggested_for` name a profile the
  caller must be able to read (404 otherwise), checked here before the
  filter runs.
  """

  alias Core.Access
  alias Core.Access.Jobs, as: JobAccess
  alias Core.Jobs
  alias Core.Jobs.{Sheet, Suggest}
  alias Data.Filters
  alias Data.Filters.JobsSort
  alias Data.JobList
  alias Data.JobParts
  alias Data.Leads, as: LeadStore
  alias Data.Profiles
  alias Data.Scope

  @page 50

  @doc "A page: `{:ok, %{items: [row], next_cursor}}`."
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    where = params["$where"]

    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, profile} <- readable_profile(scope, profile_id(where, "suggested_for")),
         {:ok, applied} <- applied_keys(scope, profile_id(where, "not_applied_with")),
         {:ok, pairs} <- Filters.order(JobsSort, params["$order"]),
         {:ok, money_sort} <- money_sort(where, params["currency"]),
         {:ok, sort} <- sort(pairs, money_sort),
         sort = if(profile, do: :suggested, else: sort),
         {:ok, cursor} <- decode(params["cursor"], sort),
         context =
           Filters.context(scope,
             now: now,
             team_id: team.id,
             suggested_for: profile && profile.id,
             applied_keys: applied
           ),
         {:ok, query} <- JobList.matching(team.id, visible_to(scope, team.id), where, context) do
      profiles = Sheet.profiles(scope, team.id)
      {jobs, next} = page(query, sort, money_sort, cursor, profile, now)
      best = Sheet.best(jobs, profiles, now)
      {:ok, %{items: Enum.map(jobs, &Sheet.row(&1, Map.get(best, &1.id))), next_cursor: next}}
    end
  end

  # `{user_id, peers?}` for `Data.JobList`: a member at `hidden` lists their own.
  defp visible_to(scope, team_id) do
    case JobAccess.pool_reach(scope, team_id) do
      {:own, me} -> {me, false}
      _all -> :all
    end
  end

  defp page(query, :suggested, _money_sort, cursor, profile, now) do
    dismissed = MapSet.new(JobParts.dismissed_jobs(profile.id))

    scored =
      query
      |> JobList.all()
      |> Enum.reject(&MapSet.member?(dismissed, &1.id))
      |> Enum.map(&{Suggest.score(profile, &1, now).score, &1})
      |> Enum.filter(fn {score, _job} -> score >= Suggest.threshold() end)
      |> Enum.sort_by(fn {score, job} -> {-score, reverse(job.id)} end)
      |> Enum.drop_while(fn {score, job} -> not after?({score, job.id}, cursor) end)

    {rows, more} = Enum.split(scored, @page)

    next =
      if more == [],
        do: nil,
        else: rows |> List.last() |> then(fn {s, j} -> encode(:suggested, s, j.id) end)

    {Enum.map(rows, &elem(&1, 1)), next}
  end

  defp page(query, sort, money_sort, cursor, _profile, _now) do
    jobs = JobList.page(query, sort, money_sort, cursor, @page)
    {rows, more} = Enum.split(jobs, @page)

    next =
      if more == [],
        do: nil,
        else: encode(sort, key(sort, List.last(rows), money_sort), List.last(rows).id)

    {rows, next}
  end

  # Ids descending, as the SQL's tie-break: sorting by the inverted bytes.
  defp reverse(id), do: id |> Ecto.UUID.dump!() |> :binary.bin_to_list() |> Enum.map(&(255 - &1))

  defp after?(_entry, nil), do: true

  defp after?({score, id}, {c_score, c_id}),
    do: score < c_score or (score == c_score and reverse(id) > reverse(c_id))

  defp key(:newest, job, _money_sort), do: job.first_seen_at
  defp key(:posted, job, _money_sort), do: job.posted_on
  defp key(:money, job, money_sort), do: JobList.money_key(job, money_sort)

  # ── Parameters ──────────────────────────────────────────────────────────────

  # The sort: one `$order` field; money needs a currency.
  defp sort([], _money_sort), do: {:ok, :newest}
  defp sort([{"first_seen_at", _dir}], _money_sort), do: {:ok, :newest}
  defp sort([{"posted_on", _dir}], _money_sort), do: {:ok, :posted}
  defp sort([{"money", _dir}], nil), do: invalid("currency", "is needed to sort by money")
  defp sort([{"money", _dir}], _money_sort), do: {:ok, :money}

  defp sort(_pairs, _money_sort),
    do: {:error, {:invalid_filter, %{"$order" => ["sorts by one field"]}}}

  # The money sort's currency: the money filter's (a project budget sorts
  # only projects), else the `currency` switch's. A bad money filter is
  # `Data.Filters`' 422, so here it only gives no currency.
  defp money_sort(where, currency) do
    with %{"$GTE" => %{} = value} <- Filters.value(where, "money"),
         {:ok, money} <- Filters.Jobs.money(value) do
      {:ok, %{currency: money.currency, project?: money.period == :project}}
    else
      _no_filter -> currency_switch(currency)
    end
  end

  defp currency_switch(nil), do: {:ok, nil}
  defp currency_switch(""), do: {:ok, nil}

  defp currency_switch(value) do
    case Filters.Jobs.currency(value) do
      {:ok, code} -> {:ok, %{currency: code, project?: false}}
      :error -> invalid("currency", "is not an ISO currency code")
    end
  end

  # The profile id a `$where` field names at its top (`{"$EQUAL": id}` or
  # bare), or nil; anything else `Data.Filters` refuses.
  defp profile_id(where, field) do
    case Filters.value(where, field) do
      %{"$EQUAL" => id} when is_binary(id) and id != "" -> id
      id when is_binary(id) and id != "" -> id
      _none -> nil
    end
  end

  # The keys the profile applied on, in any team, for `not_applied_with`.
  defp applied_keys(_scope, nil), do: {:ok, %{}}

  defp applied_keys(scope, id) do
    with {:ok, profile} <- readable_profile(scope, id),
         do:
           {:ok,
            %{profile.id => LeadStore.applied_keys(Scope.organisation_id(scope), profile.id)}}
  end

  defp readable_profile(_scope, nil), do: {:ok, nil}

  defp readable_profile(scope, id) do
    with %{} = profile <- Profiles.get(id) || {:error, :not_found},
         true <-
           profile.customer.organisation_id == Scope.organisation_id(scope) ||
             {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:profile, profile}) do
      {:ok, profile}
    end
  end

  # ── The cursor: opaque to the client ────────────────────────────────────────

  defp encode(sort, key, id),
    do: Base.url_encode64(Jason.encode!([Atom.to_string(sort), plain(key), id]), padding: false)

  defp plain(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp plain(%Date{} = on), do: Date.to_iso8601(on)
  defp plain(value), do: value

  defp decode(nil, _sort), do: {:ok, nil}

  defp decode(cursor, sort) do
    tag = Atom.to_string(sort)

    with {:ok, json} <- Base.url_decode64(to_text(cursor), padding: false),
         {:ok, [^tag, key, id]} <- Jason.decode(json),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, key} <- unplain(sort, key) do
      {:ok, {key, id}}
    else
      _invalid -> invalid("cursor", "is not a cursor of this list")
    end
  end

  defp unplain(:newest, at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {:ok, at}
      error -> error
    end
  end

  defp unplain(:posted, nil), do: {:ok, nil}
  defp unplain(:posted, on) when is_binary(on), do: Date.from_iso8601(on)
  defp unplain(:money, value) when is_integer(value) or is_nil(value), do: {:ok, value}
  defp unplain(:suggested, value) when is_integer(value), do: {:ok, value}
  defp unplain(_sort, _key), do: :error

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
