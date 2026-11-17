defmodule Core.Behaviour do
  @moduledoc """
  Behaviour (AQ-10 P10.0–P10.2, §11.4): what was seen of companies and
  contacts, and what it says.

  - **`observe/2`** is every writer's one door (§6.1): it inserts the
    observation once by its unique keys (a second capture of the same
    fact writes nothing), bumps `subject_hours` in the same transaction,
    matches the subject's watches (`Core.Watches.match/1`) and, after the
    commit, sends `observation_added {kind, id}` on `team:<id>` for each
    team that touches the subject. Inside a caller's `Core.Tasks.Write`
    commit it joins that commit, so it commits with the change that
    caused it. The writers are `Core.Behaviour.Sources`'; the two routes
    that log one are `Core.Behaviour.Log`'s; *Forget* and the sweep are
    `Core.Behaviour.Privacy`'s.
  - **The reads**: a subject's summary (on the company and contact pages
    and in the extension), its page (heat map, timeline, jobs) and the
    Behaviour list. The pattern is `Core.Behaviour.Pattern`'s, computed on
    read; the shapes are `Core.Behaviour.Sheet`'s.

  **Access** (§4): staff of a team that touches the subject (its jobs,
  leads or conversations), the system admin all, customers never
  (`Core.Access`, `{:behaviour, _}`); anything else is not found.
  """

  alias Core.Access
  alias Core.Behaviour.{Pattern, Sheet}
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Core.Watches
  alias Data.Behaviour, as: Store
  alias Data.Behaviour.{Observation, Subjects}
  alias Data.Companies
  alias Data.Contacts
  alias Data.Scope

  @weeks 12
  @page 30
  @list_page 50

  # ── The door ────────────────────────────────────────────────────────────────

  @doc """
  Writes one observation (`attrs` as `Data.Behaviour.Observation` takes
  them, without `organisation_id` and `inserted_at`, which are the
  scope's and `now`'s; `observer_user_id` defaults to the scope's
  person). `attrs[:now]`, popped, is when the rules look — the cool-down
  and the expiry — and defaults to `observed_at`. Answers `{:ok,
  observation}`, `{:ok, :exists}` when a unique key already holds the
  fact, or the field errors.
  """
  @spec observe(Scope.t(), map()) :: {:ok, Observation.t() | :exists} | {:error, term()}
  def observe(%Scope{} = scope, attrs) do
    {now, attrs} = attrs |> Map.new() |> Map.pop(:now)

    row =
      attrs
      |> Map.put_new(:observer_user_id, Scope.user_id(scope))
      |> Map.merge(%{
        organisation_id: Scope.organisation_id(scope),
        inserted_at: now || attrs[:observed_at]
      })

    # Asked first, so a refused row never ends the caller's transaction.
    with {:ok, _valid} <-
           Ecto.Changeset.apply_action(Observation.changeset(%Observation{}, row), :insert) do
      Write.commit(fn -> insert(row) end)
    end
  end

  defp insert(row) do
    case Store.insert_observation(row) do
      {:ok, :exists} -> {:ok, :exists}
      {:ok, observation} -> {:ok, observation, written(observation)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp written(observation) do
    :ok = Store.bump_hours(observation)
    fired = Watches.match(observation)
    [fired, added(observation)]
  end

  defp added(%Observation{} = o) do
    subject = key(o)
    Enum.map(Store.team_ids(subject), &Realtime.observation_added(&1, subject))
  end

  @doc "An observation's subject: `{:company, id}` or `{:contact, id}`."
  @spec key(map()) :: Store.subject()
  def key(%{company_id: id}) when is_binary(id), do: {:company, id}
  def key(%{contact_id: id}) when is_binary(id), do: {:contact, id}

  # ── Subjects ────────────────────────────────────────────────────────────────

  @doc """
  The company or contact behind `kind` (`"company"` · `"contact"`, or the
  atom) and `id`, if the caller may take `action` on its behaviour:
  `%{kind, id, name, company, organisation_id, team_ids, zone, zone_source,
  record}` — `company` a contact's `%{id, name}`; `zone` the contact's, else
  its company's.
  """
  @spec subject(Scope.t(), atom(), term(), term()) :: {:ok, map()} | {:error, term()}
  def subject(%Scope{} = scope, action, kind, id) do
    with {:ok, kind} <- kind(kind),
         %{} = subject <- load(scope, kind, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:behaviour, subject}),
         do: {:ok, subject}
  end

  @doc "The subject a body names: exactly one of `company_id`, `contact_id`."
  @spec subject_of(Scope.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def subject_of(%Scope{} = scope, action, params) do
    case {Utils.presence(to_string(params["company_id"] || "")),
          Utils.presence(to_string(params["contact_id"] || ""))} do
      {nil, nil} ->
        {:error, {:invalid, %{"company_id" => ["give company_id or contact_id"]}}}

      {id, nil} ->
        subject(scope, action, :company, id)

      {nil, id} ->
        subject(scope, action, :contact, id)

      _both ->
        {:error, {:invalid, %{"company_id" => ["give company_id or contact_id, not both"]}}}
    end
  end

  defp kind(kind) when kind in [:company, "company"], do: {:ok, :company}
  defp kind(kind) when kind in [:contact, "contact"], do: {:ok, :contact}
  defp kind(_kind), do: {:error, :not_found}

  @doc false
  # The subject read for the system (the matcher, the sweep): no access asked.
  def load(%Scope{} = scope, :company, id) do
    case Companies.get(Scope.organisation_id(scope), id) do
      nil -> nil
      company -> company_subject(company)
    end
  end

  def load(%Scope{} = scope, :contact, id) do
    case Contacts.get(Scope.organisation_id(scope), id) do
      nil -> nil
      contact -> contact_subject(contact)
    end
  end

  defp company_subject(c) do
    %{
      kind: :company,
      id: c.id,
      name: c.name,
      company: nil,
      organisation_id: c.organisation_id,
      team_ids: Store.team_ids({:company, c.id}),
      zone: c.time_zone,
      zone_source: c.time_zone && c.time_zone_source,
      record: c
    }
  end

  defp contact_subject(c) do
    company = c.company

    {zone, source} =
      cond do
        is_binary(c.time_zone) -> {c.time_zone, :manual}
        company && company.time_zone -> {company.time_zone, company.time_zone_source}
        true -> {nil, nil}
      end

    %{
      kind: :contact,
      id: c.id,
      name: c.name,
      company: company && %{id: company.id, name: company.name},
      organisation_id: c.organisation_id,
      team_ids: Store.team_ids({:contact, c.id}),
      zone: zone,
      zone_source: source,
      record: c
    }
  end

  # ── The summary ─────────────────────────────────────────────────────────────

  @doc """
  The **behaviour** summary of a subject the caller may read (§11.4):
  `{sentence, enough, seen, last_seen?, time_zone, time_zone_source?,
  watchers, mine}`, plus the page's `reply_delay` and `cadence`.
  """
  @spec summary(Scope.t(), map(), DateTime.t()) :: map()
  def summary(%Scope{} = scope, subject, %DateTime{} = now) do
    key = {subject.kind, subject.id}
    zone = Core.Tasks.zone(scope)
    facts = Map.fetch!(Store.facts([key], since(now)), key)
    first_seen = first_seen([key], zone)

    facts
    |> Pattern.summary(%{zone: zone, now: now, first_seen: Map.get(first_seen, subject.id, [])})
    |> Map.merge(%{
      time_zone: subject.zone,
      time_zone_source: subject.zone_source,
      watchers: Map.get(Subjects.watchers([key]), key, []),
      mine: Watches.mine_on(scope, key, now)
    })
  end

  @doc """
  The summary for a company or contact page, or `nil` when the caller may
  not read its behaviour (a contact no team of theirs touches).
  """
  @spec summary_for(Scope.t(), atom(), binary(), DateTime.t()) :: map() | nil
  def summary_for(%Scope{} = scope, kind, id, %DateTime{} = now) do
    case subject(scope, :read, kind, id) do
      {:ok, subject} -> summary(scope, subject, now)
      {:error, _unseen} -> nil
    end
  end

  defp since(now), do: DateTime.add(now, -@weeks * 7 * 86_400, :second)

  defp first_seen(keys, zone),
    do: Store.same_day_first_seen(for({:company, id} <- keys, do: id), zone)

  # ── The subject's page ──────────────────────────────────────────────────────

  @doc """
  `GET /behaviour/:kind/:id`: `{subject, behaviour, heat, reply_delay,
  cadence, observations: {items, next_cursor}, jobs}` — `jobs` a company's
  newest 20 the caller may see, `[]` for a contact.
  """
  @spec page(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, kind, id, %DateTime{} = now) do
    with {:ok, subject} <- subject(scope, :read, kind, id),
         {:ok, observations} <- observations_of(scope, subject, nil) do
      summary = summary(scope, subject, now)
      key = {subject.kind, subject.id}
      cells = Map.fetch!(Store.facts([key], since(now)), key).hours
      ours = Core.Tasks.zone(scope)

      {:ok,
       %{
         subject: Sheet.subject(subject),
         behaviour: summary,
         heat: %{
           ours: %{zone: ours, cells: Pattern.heat(cells, ours, now)},
           theirs:
             subject.zone && %{zone: subject.zone, cells: Pattern.heat(cells, subject.zone, now)}
         },
         reply_delay: summary.reply_delay,
         cadence: summary.cadence,
         observations: observations,
         jobs: jobs(scope, subject)
       }}
    end
  end

  defp jobs(_scope, %{kind: :contact}), do: []

  defp jobs(scope, %{kind: :company, id: id}) do
    teams = if Scope.admin?(scope), do: :all, else: Scope.team_ids(scope)

    id
    |> Subjects.company_jobs(teams, 60)
    |> Enum.filter(&Access.can?(scope, :read, {:job, &1}))
    |> Enum.take(20)
    |> Enum.map(&Core.Jobs.Sheet.row(&1, nil))
  end

  @doc "`GET /behaviour/:kind/:id/observations?cursor`: `{items, next_cursor}`, 30 a page."
  @spec observations(Scope.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def observations(%Scope{} = scope, kind, id, params) do
    with {:ok, subject} <- subject(scope, :read, kind, id),
         do: observations_of(scope, subject, params["cursor"])
  end

  defp observations_of(scope, subject, cursor) do
    with {:ok, after_key} <- Sheet.decode_cursor(cursor) do
      rows = Store.page({subject.kind, subject.id}, after_key, @page)
      items = Enum.take(rows, @page)
      next = if length(rows) > @page, do: Sheet.encode_cursor(List.last(items))
      {:ok, %{items: Enum.map(items, &Sheet.observation(scope, &1)), next_cursor: next}}
    end
  end

  # ── The Behaviour page ──────────────────────────────────────────────────────

  @doc """
  `GET /behaviour?team_id&$where&cursor`: the subjects with anything
  counted that the team touches, newest `last_seen` first, 50 a page:
  `{items: [{subject, last_seen, sentence, watchers_count, watching,
  leads_open}], next_cursor}` (an offset). `$where` is
  `Data.Filters.Behaviour`' (`q`, `kind`, `watched: me`). `team_id` is
  required, except for the system admin, who without one sees every
  subject of the organisation.
  """
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :read, {:behaviour, %{team_ids: Scope.team_ids(scope)}}),
         {:ok, teams} <- teams(scope, params),
         {:ok, offset} <- Sheet.decode_offset(params["cursor"]),
         {:ok, rows} <-
           Subjects.list(
             Scope.organisation_id(scope),
             teams,
             params["$where"],
             Data.Filters.context(scope, now: now),
             offset: offset,
             limit: @list_page
           ) do
      items = Enum.take(rows, @list_page)
      next = if length(rows) > @list_page, do: Sheet.encode_offset(offset + @list_page)
      {:ok, %{items: rows_view(scope, items, teams, now), next_cursor: next}}
    end
  end

  defp teams(scope, params) do
    case {blank(params["team_id"]), Scope.admin?(scope)} do
      {nil, true} -> {:ok, :all}
      _named -> with {:ok, team} <- Core.Jobs.team(scope, params), do: {:ok, [team.id]}
    end
  end

  defp rows_view(scope, rows, teams, now) do
    keys = Enum.map(rows, &{&1.kind, &1.id})
    zone = Core.Tasks.zone(scope)
    facts = Store.facts(keys, since(now))
    first_seen = first_seen(keys, zone)
    watchers = Subjects.watchers(keys)
    leads = Subjects.open_leads(keys, teams)
    me = Scope.user_id(scope)

    for row <- rows, key = {row.kind, row.id} do
      pattern =
        Pattern.summary(Map.fetch!(facts, key), %{
          zone: zone,
          now: now,
          first_seen: Map.get(first_seen, row.id, [])
        })

      people = Map.get(watchers, key, [])

      %{
        subject: %{
          kind: row.kind,
          id: row.id,
          name: row.name,
          company: row.company_id && %{id: row.company_id, name: row.company_name}
        },
        last_seen: pattern.last_seen,
        sentence: pattern.sentence,
        watchers_count: length(people),
        watching: Enum.any?(people, &(&1.id == me)),
        leads_open: Map.get(leads, key, 0)
      }
    end
  end

  defp blank(value) when is_binary(value), do: Utils.presence(value)
  defp blank(_value), do: nil
end
