defmodule Data.Filters.Leads do
  @moduledoc """
  The leads board's and the Tracker's `$where` (AQ-11B §3 #2, #3, §11.4),
  one module for both. The team's leads, cut to the caller's reach
  (`peer_leads`), are the base query's (`Data.Leads.team_query/1`, which
  names the bindings below: `lead`, `job`, `company`, `profile`,
  `customer`, `stage`, `version`); this narrows them. `archived` is
  `false` unless the person sends it (the list's default).

  | Field | Operators | Is |
  |---|---|---|
  | `state` | `$EQUAL` `$NOT_EQUAL` `$IN` `$NOT_IN` | `lead_states` |
  | `profile` | `$EQUAL` `$IN` | the lead's profile id |
  | `customer` | `$EQUAL` `$IN` | the profile's customer id |
  | `source` `engagement` `workplace` | `$EQUAL` `$IN` | the job's, by key |
  | `stage` | `$EQUAL` `$IN` | the lead's stage key (`screening`, `custom.<slug>`) |
  | `pipeline` | `$EQUAL` | `employment` · `freelance` |
  | `owner` | `$EQUAL` `$IN` | a user id, or `"me"` |
  | `label` | `$EQUAL` `$IN` | label ids, **the team's** (another's is a 422): wearing any of them |
  | `archived` | `$EQUAL` `$IN` | `true`: only the archived; `false` (the default): only the live; `$IN [true, false]`: both (what the dashboards' tiles count) |
  | `q` | `$ILIKE` | the words, normalised: the job's title or the company's name, by substring |
  | `quiet` | `$EQUAL` | `30` · `60`: no activity for that many days (before *now*) |
  | `missing` | `$EQUAL` `$IN` | `money` (the job names no amount) · `cv` (no CV chosen): missing any of them |
  | `stage_kind` | `$EQUAL` `$IN` | the current stage's engine kind, in any pipeline (a custom stage counts as its anchor) |
  | `applied_on` | `$BETWEEN` `$EQUAL` | local days `[from, to]`, both kept, in the organisation's zone: an `applied` row of the ledger then |
  | `applied_by` | `$EQUAL` | a user id, or `"me"`: an `applied` row of the ledger by them |
  | `had_response` | `$EQUAL` | `true`: an `applied` row with a response at or after it (AQ-11 §4, `Data.Dashboards.reached/2`); `false`: one without |
  | `interviewed_on` | `$BETWEEN` `$EQUAL` | local days `[from, to]`, both kept, in the organisation's zone: an interview then by the *Interviews* tile's rule (`Data.Dashboards.interviewed_leads/3`: a stage reached of an interview kind, or a meeting of an interview kind, scheduled, done or a no-show) |
  | `follow_up` | `$EQUAL` | `"due"`: In progress and live here; the rest of P4b's rule (`Core.Leads.FollowUps`) is Elixir and runs on the rows the list already reads signals for (top level only) |

  **The tile filters read as one** (P11's links): `applied_on`,
  `applied_by` and `had_response` at the top level name the *same*
  `applied` row, as `Data.Dashboards.applications/4` counts it, so
  *Responses today* opens exactly the leads behind the tile
  (`applied_spec/2`, `applied_rows/1`; the Tracker counts the same rows as
  its `applications`, since a lead applied twice is two applications).
  `had_response` and `interviewed_on` need `context.rules`
  (`Core.Dashboards.Rules.counting/0`, handed in by the caller: data never
  names core). The tiles count archived leads too: their links send
  `archived {$IN: [true, false]}`.
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      state: ["$EQUAL", "$NOT_EQUAL", "$IN", "$NOT_IN"],
      profile: {:profile_id, ["$EQUAL", "$IN"]},
      customer: [customer: {:id, ["$EQUAL", "$IN"]}],
      job: [
        source: ["$EQUAL", "$IN"],
        engagement: ["$EQUAL", "$IN"],
        workplace: ["$EQUAL", "$IN"]
      ],
      stage: [stage: {:key, ["$EQUAL", "$IN"]}],
      version: [pipeline: {:pipeline_key, ["$EQUAL"]}]
    ],
    overrideable: [
      "owner",
      "label",
      "archived",
      "q",
      "quiet",
      "missing",
      "stage_kind",
      "applied_on",
      "applied_by",
      "had_response",
      "follow_up",
      "interviewed_on"
    ],
    ignoreable: [
      state: ["", nil, []],
      profile: ["", nil, []],
      customer: ["", nil, []],
      source: ["", nil, []],
      engagement: ["", nil, []],
      workplace: ["", nil, []],
      stage: ["", nil, []],
      pipeline: ["", nil],
      owner: ["", nil, []],
      label: ["", nil, []],
      q: ["", "%%", nil],
      quiet: ["", nil],
      missing: ["", nil, []],
      stage_kind: ["", nil, []],
      interviewed_on: ["", nil, []]
    ]

  use Data.Filters,
    operators: [
      owner: ["$EQUAL", "$IN"],
      label: ["$EQUAL", "$IN"],
      archived: ["$EQUAL", "$IN"],
      q: ["$ILIKE"],
      quiet: ["$EQUAL"],
      missing: ["$EQUAL", "$IN"],
      stage_kind: ["$EQUAL", "$IN"],
      applied_on: ["$BETWEEN", "$EQUAL"],
      applied_by: ["$EQUAL"],
      had_response: ["$EQUAL"],
      follow_up: ["$EQUAL"],
      interviewed_on: ["$BETWEEN", "$EQUAL"]
    ]

  import Ecto.Query

  alias Data.Companies.Company
  alias Data.Filters
  alias Data.Labels
  alias Data.Labels.LeadLabel
  alias Data.Leads.Event

  @quiet [30, 60]
  @missing ~w(money cv)
  @applied ~w(applied_on applied_by had_response)

  # ── Reading what a person sent ──────────────────────────────────────────────

  @impl Data.Filters
  def prepare("owner", _op, value, context), do: owners(value, context)

  def prepare("label", _op, value, context) do
    with {:ok, ids} <- Filters.ids(value),
         ids = Enum.uniq(ids),
         true <- (ids != [] and is_binary(context[:team_id])) || :error,
         true <- length(Labels.in_team(context.team_id, ids)) == length(ids) || :error,
         do: {:ok, ids}
  end

  def prepare("archived", "$IN", values, _context) do
    values
    |> Filters.listed()
    |> Enum.map(&Filters.boolean/1)
    |> Enum.uniq()
    |> case do
      [{:ok, flag}] -> {:ok, flag}
      [_one, _other] = both -> if :error in both, do: :error, else: {:ok, :any}
      _bad -> :error
    end
  end

  def prepare("archived", _op, value, _context), do: Filters.boolean(value)

  def prepare("interviewed_on", op, value, context) do
    with {:ok, %{window: window}} <- days(op, value, context),
         rules when is_map(rules) <- context[:rules] || :error,
         org when is_binary(org) <- context[:organisation_id] || :error,
         do: {:ok, {:interviewed, org, rules, window}}
  end

  def prepare("q", _op, value, _context) do
    with {:ok, text} <- Filters.words(value), do: {:ok, Company.normalize(text)}
  end

  def prepare("quiet", _op, value, %{now: %DateTime{} = now}) do
    with {:ok, days} <- Filters.integer(value, @quiet),
         do: {:ok, DateTime.add(now, -days * 86_400, :second)}
  end

  def prepare("missing", _op, value, _context), do: Filters.keys(value, @missing)

  def prepare("stage_kind", _op, value, _context),
    do: Filters.keys(value, Data.Vocabulary.stage_kinds())

  def prepare("follow_up", "$EQUAL", "due", _context), do: {:ok, :due}

  def prepare(field, op, value, context) when field in @applied do
    with {:ok, own} <- applied_part(field, op, value, context) do
      if top_level?(field, value, context),
        do: {:ok, {:applied, applied_spec(context[:where], context)}},
        else: {:ok, {:applied, Map.merge(own, basis(context))}}
    end
  end

  def prepare(_field, _op, _value, _context), do: :error

  defp owners(value, context) do
    value
    |> Filters.listed()
    |> Enum.reduce_while({:ok, []}, fn one, {:ok, acc} ->
      case Filters.me_or_id(one, context) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, []} -> :error
      other -> other
    end
  end

  # One part of the `applied` row a person asked about.
  defp applied_part("applied_on", op, value, context), do: days(op, value, context)

  defp applied_part("applied_by", "$EQUAL", value, context) do
    with {:ok, id} <- Filters.me_or_id(value, context), do: {:ok, %{by: id}}
  end

  defp applied_part("had_response", "$EQUAL", value, context) do
    with {:ok, flag} <- Filters.boolean(value),
         true <- is_map(context[:rules]) || :error,
         do: {:ok, %{responded: flag}}
  end

  defp applied_part(_field, _op, _value, _context), do: :error

  # Local days `[from, to]` (or one) in the organisation's zone, as the
  # dashboards' window.
  defp days("$BETWEEN", value, context) do
    with [from, to] <- Filters.listed(value),
         {:ok, first} <- Filters.date(from),
         {:ok, last} <- Filters.date(to),
         true <- Date.compare(first, last) != :gt do
      {:ok, %{window: Filters.day_range(first, last, zone(context))}}
    else
      _bad -> :error
    end
  end

  defp days("$EQUAL", value, context) do
    with {:ok, day} <- Filters.date(value),
         do: {:ok, %{window: Filters.day_range(day, day, zone(context))}}
  end

  defp days(_op, _value, _context), do: :error

  @doc """
  The `applied` rows a top-level `$where` asks about: its `applied_on`,
  `applied_by` and `had_response` read together, as one row — the spec
  `applied_rows/1` takes, with `context`'s organisation and `rules` — or
  `nil` when it names none of them. The filter reads them so, and the
  Tracker's `applications` count (AQ-11B §11.5) reads the same spec, so the
  rule is written once. A part the list refused (a 422 before this) is
  left out.
  """
  @spec applied_spec(term(), map()) :: map() | nil
  def applied_spec(where, context) do
    where =
      case Filters.decode(where) do
        {:ok, map} -> map
        {:error, _refusal} -> %{}
      end

    parts =
      for field <- @applied,
          raw = Map.get(where, field),
          raw != nil,
          {op, value} <- pairs(raw),
          {:ok, part} <- [applied_part(field, op, value, context)],
          do: part

    if parts == [], do: nil, else: Enum.reduce(parts, basis(context), &Map.merge(&2, &1))
  end

  defp top_level?(field, value, context) do
    case Map.get(Map.get(context, :where) || %{}, field) do
      nil -> false
      raw -> Enum.any?(pairs(raw), fn {_op, v} -> v == value end)
    end
  end

  defp pairs(raw) when is_map(raw) and not is_struct(raw),
    do: Enum.map(raw, fn {op, v} -> {String.upcase(to_string(op)), v} end)

  defp pairs(raw), do: [{"$EQUAL", raw}]

  defp basis(context),
    do: %{organisation_id: context[:organisation_id], rules: context[:rules]}

  defp zone(context), do: context[:zone] || "Etc/UTC"

  # ── Building ────────────────────────────────────────────────────────────────

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("owner", _op, ids) when is_list(ids),
    do: dynamic([lead: l], l.owner_user_id in ^ids)

  def override_buildable("label", _op, ids) when is_list(ids) do
    worn = from(ll in LeadLabel, where: ll.label_id in ^ids, select: ll.lead_id)
    dynamic([lead: l], l.id in subquery(worn))
  end

  def override_buildable("archived", _op, true),
    do: dynamic([lead: l], not is_nil(l.archived_at))

  def override_buildable("archived", _op, false),
    do: dynamic([lead: l], is_nil(l.archived_at))

  def override_buildable("archived", _op, :any), do: nil

  def override_buildable("q", "$ILIKE", qn) when is_binary(qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"

    dynamic(
      [job: j, company: c],
      fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or like(c.name_normalized, ^like)
    )
  end

  def override_buildable("quiet", "$EQUAL", %DateTime{} = before),
    do: dynamic([lead: l], l.last_activity_at < ^before)

  def override_buildable("missing", _op, keys) when is_list(keys) do
    Enum.reduce(keys, dynamic(false), fn
      :money, acc ->
        dynamic([job: j], ^acc or (is_nil(j.comp_min_minor) and is_nil(j.comp_max_minor)))

      :cv, acc ->
        dynamic([lead: l], ^acc or is_nil(l.document_id))
    end)
  end

  def override_buildable("stage_kind", _op, kinds) when is_list(kinds) do
    dynamic(
      [stage: s],
      (s.kind != :custom and s.kind in ^kinds) or (s.kind == :custom and s.anchor_kind in ^kinds)
    )
  end

  def override_buildable("follow_up", "$EQUAL", :due),
    do: dynamic([lead: l], l.state == :in_progress and is_nil(l.archived_at))

  def override_buildable("interviewed_on", _op, {:interviewed, org, rules, window}) do
    interviewed = Data.Dashboards.interviewed_leads(org, rules, window)
    dynamic([lead: l], l.id in subquery(interviewed))
  end

  def override_buildable(field, "$" <> _op, {:applied, spec}) when field in @applied do
    rows = where(applied_rows(spec), [applied: e], e.lead_id == parent_as(:lead).id)
    dynamic([lead: l], exists(rows))
  end

  def override_buildable(_field, _operator, _value), do: nil

  @doc """
  The ledger's `applied` rows matching every part of `spec`
  (`applied_spec/2`): in the window, by the person, with (or without) a
  response at or after it — AQ-11 §4's rule, `Data.Dashboards.reached/2`,
  as the *Applications* and *Responses* tiles count it. Uncorrelated, named
  `:applied`: the filter asks whether a lead has one, the Tracker counts
  them on its listed leads.
  """
  @spec applied_rows(map()) :: Ecto.Query.t()
  def applied_rows(spec) do
    from(e in Event, as: :applied, where: e.kind == :applied)
    |> organisation(spec[:organisation_id])
    |> window(spec[:window])
    |> by(spec[:by])
    |> responded(spec[:responded], spec)
  end

  defp organisation(rows, nil), do: rows
  defp organisation(rows, id), do: where(rows, [applied: e], e.organisation_id == ^id)

  defp window(rows, nil), do: rows

  defp window(rows, {from, to}),
    do: where(rows, [applied: e], e.occurred_at >= ^from and e.occurred_at < ^to)

  defp by(rows, nil), do: rows
  defp by(rows, id), do: where(rows, [applied: e], e.actor_user_id == ^id)

  defp responded(rows, nil, _spec), do: rows

  defp responded(rows, flag, %{organisation_id: org, rules: rules}) do
    reached = Data.Dashboards.reached(org, rules)

    rows =
      join(rows, :left, [applied: e], r in subquery(reached),
        as: :reached,
        on: r.lead_id == e.lead_id
      )

    if flag,
      do: where(rows, [applied: e, reached: r], r.responded_at >= e.occurred_at),
      else:
        where(
          rows,
          [applied: e, reached: r],
          is_nil(r.responded_at) or r.responded_at < e.occurred_at
        )
  end
end
