defmodule Data.Filters.Jobs do
  @moduledoc """
  `GET /team/v1/jobs`'s `$where` (AQ-03 §7.1, AQ-11B §3 #1): one team's
  pool. The team and who of it sees which job (`peer_jobs`) are the base
  query's (`Data.JobList.matching/4`); this narrows them. Live jobs only
  unless `archived` is sent (`Data.JobList` defaults it to `false`).

  | Field | Operators | Is |
  |---|---|---|
  | `source` `engagement` `workplace` `remote_scope` `status` | `$EQUAL` `$IN` | the job's key, or any of them |
  | `origin_kind` | `$EQUAL` `$IN` | what brought it (AQ-12 §11.4): `alert` is the pool's *From alerts* (the console's `from=alert`); `brief` · `inquiry` · `order` a Fiverr job's |
  | `q` | `$ILIKE` | the words, normalised: the title by substring or trigram (accents and case ignored), or the company's name |
  | `country` | `$EQUAL` | an ISO code: `allowed_countries` holds it, or the job is remote worldwide |
  | `skills` | `$IN` | skill ids: the job has any of them |
  | `money` | `$GTE` | `{min_minor, currency, period}`, all three (QP3-9): the job's top in `currency`, annualised, at least `min_minor` annualised; a `project` budget only against project budgets |
  | `posted_within` | `$EQUAL` | 1 · 3 · 7 · 14 · 30 days before *now*: `posted_on`, else `first_seen_at` |
  | `archived` | `$EQUAL` | `true`: only the archived; `false`: only the live |
  | `has_leads` | `$EQUAL` | `true`: a job with a lead, whatever its state; `false`: none (AQ-04A §8.1) |
  | `not_applied_with` | `$EQUAL` | a profile id: no lead past To do for it on the posting, in any team — the keys come from the context (`applied_keys`), put there by `Core.Jobs.Pool` after it checks the caller may read the profile |
  | `suggested_for` | `$EQUAL` | a profile id: **scored in memory** (`Core.Jobs.Suggest`, ≥ 70 and not dismissed, best first) by `Core.Jobs.Pool`, which checks the profile and names it in the context (`suggested_for`); it builds no SQL |

  `money`'s value as query parameters:
  `$where[money][$GTE][min_minor]=400000&$where[money][$GTE][currency]=USD&$where[money][$GTE][period]=month`.
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      source: ["$EQUAL", "$IN"],
      engagement: ["$EQUAL", "$IN"],
      workplace: ["$EQUAL", "$IN"],
      remote_scope: ["$EQUAL", "$IN"],
      status: ["$EQUAL", "$IN"],
      origin_kind: ["$EQUAL", "$IN"]
    ],
    overrideable: [
      "q",
      "country",
      "skills",
      "money",
      "posted_within",
      "archived",
      "has_leads",
      "not_applied_with",
      "suggested_for"
    ],
    ignoreable: [
      q: ["", "%%", nil],
      country: ["", nil],
      skills: [[], "", nil],
      source: [[], "", nil],
      engagement: [[], "", nil],
      workplace: [[], "", nil],
      remote_scope: [[], "", nil],
      status: [[], "", nil],
      origin_kind: [[], "", nil],
      posted_within: ["", nil],
      not_applied_with: ["", nil],
      suggested_for: ["", nil]
    ]

  use Data.Filters,
    operators: [
      q: ["$ILIKE"],
      country: ["$EQUAL"],
      skills: ["$IN"],
      money: ["$GTE"],
      posted_within: ["$EQUAL"],
      archived: ["$EQUAL"],
      has_leads: ["$EQUAL"],
      not_applied_with: ["$EQUAL"],
      suggested_for: ["$EQUAL"]
    ]

  import Ecto.Query

  alias Data.Companies.Company
  alias Data.Filters
  alias Data.Jobs.{JobSkill, Merge}
  alias Data.Leads.Lead
  alias Data.Vocabulary

  @within [1, 3, 7, 14, 30]

  # ── The words a person sends ────────────────────────────────────────────────

  @impl Data.Filters
  def prepare("q", "$ILIKE", value, _context) do
    with {:ok, text} <- Filters.words(value), do: {:ok, Company.normalize(text)}
  end

  def prepare("country", "$EQUAL", value, _context) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if code =~ ~r/^[A-Z]{2}$/, do: {:ok, code}, else: :error
  end

  def prepare("skills", "$IN", value, _context), do: Filters.ids(value)

  def prepare("money", "$GTE", %{} = value, _context), do: money(value)

  def prepare("posted_within", "$EQUAL", value, %{now: %DateTime{} = now}) do
    with {:ok, days} <- Filters.integer(value, @within) do
      since = DateTime.add(now, -days * 86_400, :second)
      {:ok, {DateTime.to_date(since), since}}
    end
  end

  def prepare(field, "$EQUAL", value, _context) when field in ["archived", "has_leads"],
    do: Filters.boolean(value)

  # The keys of a profile the pool checked the caller may read; any other is refused.
  def prepare("not_applied_with", "$EQUAL", value, context) do
    with {:ok, id} <- Filters.id(value),
         {:ok, keys} <- Map.fetch(context[:applied_keys] || %{}, id),
         do: {:ok, {:keys, keys}}
  end

  def prepare("suggested_for", "$EQUAL", value, context) do
    with {:ok, id} <- Filters.id(value),
         true <- context[:suggested_for] == id || :error,
         do: {:ok, {:scored, id}}
  end

  def prepare(_field, _operator, _value, _context), do: :error

  @doc """
  `money`'s value read: `{:ok, %{min, currency, period}}` (`period` an
  atom of `comp_periods`), or `:error` unless all three are there and
  right. `Core.Jobs.Pool` reads the money sort's currency with it too.
  """
  @spec money(map()) :: {:ok, map()} | :error
  def money(value) do
    with {:ok, min} <- Filters.integer(value["min_minor"]),
         true <- min >= 0 || :error,
         {:ok, currency} <- currency(value["currency"]),
         {:ok, [period]} <- Filters.keys(value["period"], Vocabulary.comp_periods()) do
      {:ok, %{min: min, currency: currency, period: period}}
    else
      _bad -> :error
    end
  end

  @doc "An ISO 4217 code as sent, upper-cased: `{:ok, code}` or `:error`."
  @spec currency(term()) :: {:ok, String.t()} | :error
  def currency(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if code =~ ~r/^[A-Z]{3}$/, do: {:ok, code}, else: :error
  end

  def currency(_value), do: :error

  # ── The SQL ─────────────────────────────────────────────────────────────────

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("q", "$ILIKE", qn) when is_binary(qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"

    company =
      from(c in Company,
        where:
          c.id == parent_as(:job).company_id and
            (like(c.name_normalized, ^like) or fragment("? <% ?", ^qn, c.name_normalized))
      )

    dynamic(
      [j],
      fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or
        fragment("? <% lower(unaccent(?))", ^qn, j.title) or exists(company)
    )
  end

  def override_buildable("country", "$EQUAL", code) when is_binary(code) do
    dynamic(
      [j],
      fragment("? = ANY(?)", ^code, j.allowed_countries) or j.remote_scope == :global
    )
  end

  def override_buildable("skills", "$IN", [_ | _] = ids) do
    having = from(s in JobSkill, where: s.skill_id in ^ids, select: s.job_id)
    dynamic([j], j.id in subquery(having))
  end

  def override_buildable("money", "$GTE", %{min: min, currency: currency, period: :project}) do
    dynamic(
      [j],
      j.comp_currency == ^currency and j.comp_period == :project and
        coalesce(j.comp_max_minor, j.comp_min_minor) >= ^min
    )
  end

  def override_buildable("money", "$GTE", %{min: min, currency: currency, period: period}) do
    floor = Utils.Units.annualise(min, period)
    dynamic([j], j.comp_currency == ^currency and ^annual_top() >= ^floor)
  end

  def override_buildable("posted_within", "$EQUAL", {%Date{} = on, %DateTime{} = at}) do
    dynamic(
      [j],
      (not is_nil(j.posted_on) and j.posted_on >= ^on) or
        (is_nil(j.posted_on) and j.first_seen_at >= ^at)
    )
  end

  def override_buildable("archived", "$EQUAL", true), do: dynamic([j], not is_nil(j.archived_at))
  def override_buildable("archived", "$EQUAL", false), do: dynamic([j], is_nil(j.archived_at))

  def override_buildable("has_leads", "$EQUAL", true),
    do: dynamic([j], exists(from(l in Lead, where: l.job_id == parent_as(:job).id)))

  def override_buildable("has_leads", "$EQUAL", false),
    do: dynamic([j], not exists(from(l in Lead, where: l.job_id == parent_as(:job).id)))

  # Neither the job's key nor a key merged into it is one the profile applied on.
  def override_buildable("not_applied_with", "$EQUAL", {:keys, []}), do: dynamic([j], true)

  def override_buildable("not_applied_with", "$EQUAL", {:keys, keys}) do
    merged = from(m in Merge, where: m.from_canonical_key in ^keys, select: m.into_job_id)
    dynamic([j], j.canonical_key not in ^keys and j.id not in subquery(merged))
  end

  # The score is computed on read, in memory: nothing for the SQL to do.
  def override_buildable("suggested_for", "$EQUAL", {:scored, _id}), do: dynamic([j], true)

  def override_buildable(_field, _operator, _value), do: nil

  @doc """
  The job's top as a year's worth; NULL for a project or no money. The
  factors are `Utils.Units.annual_factors/0`'s (`Data.JobListTest` holds
  the two to the same numbers); the money sort's key reads it too.
  """
  @spec annual_top() :: Ecto.Query.dynamic_expr()
  def annual_top do
    dynamic(
      [j],
      fragment(
        "CASE ? WHEN 'hour' THEN ? * 2080 WHEN 'day' THEN ? * 260 WHEN 'week' THEN ? * 52 WHEN 'month' THEN ? * 12 WHEN 'year' THEN ? END",
        j.comp_period,
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor)
      )
    )
  end
end
