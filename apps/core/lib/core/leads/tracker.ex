defmodule Core.Leads.Tracker do
  @moduledoc """
  The Tracker (AQ-04B §8.1, §8.4, §9, QP4b-15, QP4b-18, AQ-11B §11.4):
  **every lead of the current team as one sheet**, by the team's
  `peer_leads` (a member at `hidden` sees their own). `$where` is
  `Data.Filters.Leads`' — the board's filters, `state`, `label`,
  `missing`, `pipeline` and P11's tile filters (`applied_on`,
  `applied_by`, `had_response`, `interviewed_on`, `stage_kind`,
  `follow_up`); `$order` is `Data.Filters.TrackerSort`'s (one of
  `tracker_columns`, `$ASC` · `$DESC`; last activity, newest first,
  without one); `group` (`tracker_groups`) and `cursor` are its own. Pages
  of 50 with the `total`; with an *Applied* filter, `applications` beside
  it (AQ-11B §11.5: the matching `applied` rows on every listed lead, so a
  lead applied twice shows as "1 lead · 2 applications", as the tiles
  count); when grouped, the groups with their counts over every matching
  row (rows run group by group, each sorted).

  The rows are one read of the team's matching leads (a team's worth),
  sorted by the database; *Next*, labels and *Missing* are computed on read
  (`Core.Leads.Signals`) and have no SQL form, so a sort on one of them
  **runs here, in memory**, on the same rows. `cursor` is the last row seen
  (its id and place), so *More* continues after it even when a row moved
  meanwhile.

  `csv/3` (`GET /tracker.csv`) is the same query, every matching row and
  every column (none is hidden from a reader of the team's leads), UTF-8
  with a BOM so it opens in a spreadsheet, money as written with its
  currency — never summed or converted — and the export is audited as
  `tracker_exported`.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Jobs
  alias Core.Jobs.Sheet, as: JobSheet
  alias Core.Leads.{Board, Pipelines, Signals, Words}
  alias Core.Retention.Policy
  alias Core.Tasks.Person
  alias Data.Filters.TrackerSort
  alias Data.Leads, as: Store
  alias Data.Repo
  alias Data.Scope
  alias Data.Vocabulary
  alias Plug.Conn.Query

  @page 50
  @state_order %{todo: 0, in_progress: 1, on_hold: 2, done: 3}
  @missing ~w(money cv)
  @headers %{
    "applied" => "Applied",
    "title" => "Title",
    "company" => "Company",
    "source" => "Source",
    "customer" => "Customer",
    "profile" => "Profile",
    "owner" => "Owner",
    "state" => "State",
    "outcome" => "Outcome",
    "next" => "Next",
    "last_activity" => "Last activity",
    "money" => "Money",
    "workplace" => "Workplace",
    "engagement" => "Engagement",
    "cv" => "CV",
    "labels" => "Labels",
    "missing" => "Missing"
  }

  # ── The page ────────────────────────────────────────────────────────────────

  @doc """
  `GET /tracker`: `{items, next_cursor, total, applications, groups}`.
  `applications` (AQ-11B §11.5) is `nil` unless the top-level `$where`
  names `applied_on`, `applied_by` or `had_response`; then it counts the
  ledger's `applied` rows on every listed lead (all pages, after every
  filter, `follow_up` too) that match those parts together — what the
  *Applications* and *Responses* tiles count, a lead applied twice twice —
  so the head can say "8 leads · 9 applications".
  """
  @spec page(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, %{rows: rows, group: group, team: team}} <- rows(scope, params, now),
         {:ok, start} <- cursor(rows, params["cursor"]) do
      {items, rest} = rows |> Enum.drop(start) |> Enum.split(@page)

      applications =
        Store.applications(
          Enum.map(rows, & &1.id),
          params["$where"],
          Board.context(scope, team, now)
        )

      {:ok,
       %{
         items: items,
         next_cursor: if(rest == [], do: nil, else: encode(List.last(items), start + @page - 1)),
         total: length(rows),
         applications: applications,
         groups: groups(group, rows)
       }}
    end
  end

  # ── The CSV ─────────────────────────────────────────────────────────────────

  @doc "`GET /tracker.csv`: `{:ok, csv, filename}`, audited."
  @spec csv(Scope.t(), map(), DateTime.t()) :: {:ok, iodata(), String.t()} | {:error, term()}
  def csv(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, %{rows: rows, team: team}} <- rows(scope, params, now) do
      zone = Signals.zone(scope.organisation)
      columns = Vocabulary.tracker_columns()

      lines = [
        Enum.map(columns, &Map.fetch!(@headers, &1)),
        Enum.map(rows, fn row -> Enum.map(columns, &cell(&1, row, zone)) end)
      ]

      body = ["﻿" | Enum.map([hd(lines) | List.last(lines)], &line/1)]

      {:ok, _audit} =
        Audit.record(scope, "tracker_exported", team,
          after: %{
            "team_id" => team.id,
            "rows" => length(rows),
            "query" => params |> Map.drop(~w(team team_id cursor)) |> Query.encode()
          },
          now: now
        )

      {:ok, body, "tracker-#{slug(team.name)}-#{Policy.day(now, zone)}.csv"}
    end
  end

  defp line(cells), do: [Enum.map_join(cells, ",", &escape/1), "\r\n"]

  # RFC 4180 quoting; a cell that a spreadsheet would read as a formula is
  # kept as text.
  defp escape(nil), do: ""

  defp escape(value) do
    text = to_string(value)
    text = if String.starts_with?(text, ~w(= + - @)), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  defp cell("applied", r, zone), do: r.applied_at && Policy.day(r.applied_at, zone)
  defp cell("title", r, _zone), do: r.title
  defp cell("company", r, _zone), do: r.company && r.company.name
  defp cell("source", r, _zone), do: Words.value(r.source)
  defp cell("customer", r, _zone), do: r.customer.display_name
  defp cell("profile", r, _zone), do: r.profile.title
  defp cell("owner", r, _zone), do: r.owner && r.owner.name

  defp cell("state", r, _zone),
    do: Words.place(r.state, stage_name(r), r.outcome)

  defp cell("outcome", r, _zone), do: Words.outcome(r.outcome)
  defp cell("next", r, _zone), do: r.next && r.next.words
  defp cell("last_activity", r, zone), do: Policy.day(r.last_activity_at, zone)
  defp cell("money", r, _zone), do: Utils.Money.line(r.money)
  defp cell("workplace", r, _zone), do: Words.value(r.workplace)
  defp cell("engagement", r, _zone), do: Words.value(r.engagement)
  defp cell("cv", r, _zone), do: r.cv && "#{r.cv.label} v#{r.cv.version}"
  defp cell("labels", r, _zone), do: Enum.map_join(r.labels, ", ", & &1.name)
  defp cell("missing", r, _zone), do: Enum.join(r.missing, ", ")

  defp stage_name(%{stage: %{name: name}}), do: name
  defp stage_name(_row), do: nil

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  # ── The rows ────────────────────────────────────────────────────────────────

  defp rows(scope, params, now) do
    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, group} <- choice(params["group"], Vocabulary.tracker_groups(), "group", "none"),
         {:ok, sort} <- sort(params["$order"]),
         {:ok, leads, ctx} <-
           Board.leads(scope, team, params["$where"], now, order: sql_order(sort)) do
      rows =
        leads
        |> Repo.preload(:document)
        |> Enum.map(&row(&1, Signals.for_lead(ctx, &1)))
        |> arrange(group, sort)

      {:ok, %{rows: rows, group: group, team: team}}
    end
  end

  @doc "A Tracker row (§8.4) of a lead read with its card's preloads and `document`."
  @spec row(map(), map()) :: map()
  def row(lead, signals) do
    job = lead.job
    money = JobSheet.money(job)

    %{
      id: lead.id,
      applied_at: lead.applied_at,
      title: job.title,
      company: job.company && %{id: job.company.id, name: job.company.name},
      source: job.source,
      customer: %{id: lead.profile.customer.id, display_name: lead.profile.customer.display_name},
      profile: %{id: lead.profile.id, title: lead.profile.title},
      owner: Person.view(lead.owner_user),
      state: lead.state,
      stage: Pipelines.stage(lead.stage),
      outcome: lead.outcome,
      next: signals.next,
      last_activity_at: lead.last_activity_at,
      quiet: Map.take(signals.quiet, [:archives_on, :warn]),
      money: money,
      workplace: job.workplace,
      engagement: job.engagement,
      cv: lead.document && cv(lead.document),
      labels: signals.labels,
      missing:
        Enum.filter(@missing, fn
          "money" -> is_nil(money.min_minor) and is_nil(money.max_minor)
          "cv" -> is_nil(lead.document_id)
        end)
    }
  end

  defp cv(document), do: %{id: document.id, label: document.label, version: document.version_no}

  # ── Order, groups, the cursor ───────────────────────────────────────────────

  # One column, or none (last activity, newest first): `{column, :asc | :desc}`.
  defp sort(order) do
    case Data.Filters.order(TrackerSort, order) do
      {:ok, []} -> {:ok, nil}
      {:ok, [{column, dir}]} -> {:ok, {column, if(dir == "$ASC", do: :asc, else: :desc)}}
      {:ok, _several} -> {:error, {:invalid_filter, %{"$order" => ["sorts by one column"]}}}
      error -> error
    end
  end

  defp sql_order(nil), do: nil
  defp sql_order({column, :asc}), do: TrackerSort.build(%{column => "$ASC"})
  defp sql_order({column, :desc}), do: TrackerSort.build(%{column => "$DESC"})

  # The database sorted the rows; a group keeps that order within it (a
  # stable sort), and a column computed on read sorts here.
  defp arrange(rows, group, {column, dir}) do
    if column in TrackerSort.in_memory(),
      do: in_memory(rows, group, column, dir),
      else: Enum.sort_by(rows, &group_key(group, &1))
  end

  defp arrange(rows, group, nil), do: Enum.sort_by(rows, &group_key(group, &1))

  defp in_memory(rows, group, sort, dir) do
    Enum.sort(rows, fn a, b ->
      ga = group_key(group, a)
      gb = group_key(group, b)

      if ga != gb,
        do: ga < gb,
        else: before?(sort_key(sort, a), sort_key(sort, b), dir, a.id, b.id)
    end)
  end

  # Nothing sorts last, whichever way; ties go by id so pages never overlap.
  defp before?(nil, nil, _dir, a, b), do: a <= b
  defp before?(nil, _b, _dir, _ia, _ib), do: false
  defp before?(_a, nil, _dir, _ia, _ib), do: true
  defp before?(a, a, _dir, ia, ib), do: ia <= ib
  defp before?(a, b, :asc, _ia, _ib), do: a < b
  defp before?(a, b, :desc, _ia, _ib), do: a > b

  defp sort_key("next", r), do: r.next && at(r.next.at)
  defp sort_key("labels", %{labels: []}), do: nil
  defp sort_key("labels", r), do: r.labels |> Enum.map_join(", ", & &1.name) |> down()
  defp sort_key("missing", r), do: length(r.missing)

  defp group_key("none", _r), do: 0
  defp group_key("state", r), do: Map.fetch!(@state_order, r.state)

  defp group_key("stage", r),
    do: {Map.fetch!(@state_order, r.state), (r.stage && r.stage.position) || 0}

  defp group_key("customer", r), do: {down(r.customer.display_name), r.customer.id}
  defp group_key("profile", r), do: {down(r.customer.display_name), down(r.profile.title)}
  defp group_key("owner", r), do: {r.owner && down(r.owner.name), r.owner && r.owner.user_id}
  defp group_key("source", r), do: to_string(r.source)

  defp groups("none", _rows), do: nil

  defp groups(group, rows) do
    rows
    |> Enum.chunk_by(&group_key(group, &1))
    |> Enum.map(fn [first | _] = held ->
      {key, name} = group_of(group, first)
      %{key: key, name: name, count: length(held)}
    end)
  end

  defp group_of("state", r), do: {to_string(r.state), Words.state(r.state)}

  # By state and stage: "Done · Applied" holds every outcome reached there.
  defp group_of("stage", %{stage: %{key: key, name: name}} = r),
    do: {"#{r.state}:#{key}", Words.state(r.state) <> " · " <> name}

  defp group_of("stage", r), do: {to_string(r.state), Words.state(r.state)}
  defp group_of("customer", r), do: {r.customer.id, r.customer.display_name}

  defp group_of("profile", r),
    do: {r.profile.id, "#{r.customer.display_name} · #{r.profile.title}"}

  defp group_of("owner", r), do: {r.owner && r.owner.user_id, r.owner && r.owner.name}
  defp group_of("source", r), do: {to_string(r.source), Words.value(r.source)}

  defp encode(row, index), do: Base.url_encode64("#{row.id}|#{index}", padding: false)

  defp cursor(_rows, nil), do: {:ok, 0}
  defp cursor(_rows, ""), do: {:ok, 0}

  defp cursor(rows, value) do
    with {:ok, decoded} <- Base.url_decode64(to_string(value), padding: false),
         [id, index] <- String.split(decoded, "|", parts: 2),
         {index, ""} <- Integer.parse(index) do
      case Enum.find_index(rows, &(&1.id == id)) do
        nil -> {:ok, index + 1}
        at -> {:ok, at + 1}
      end
    else
      _bad -> invalid("cursor", "is not a cursor")
    end
  end

  # ── Parameters ──────────────────────────────────────────────────────────────

  defp choice(nil, _allowed, _field, default), do: {:ok, default}
  defp choice("", _allowed, _field, default), do: {:ok, default}

  defp choice(value, allowed, field, _default) do
    if to_string(value) in allowed,
      do: {:ok, to_string(value)},
      else: invalid(field, "is not one of the list")
  end

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp down(nil), do: nil
  defp down(text), do: String.downcase(text)

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
