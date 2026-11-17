defmodule Core.Ingest.Extension.Sites do
  @moduledoc """
  What Indeed, YC Work at a Startup and Wellfound say beyond the shared
  fields (AQ-12 §4, §5, §11.4; PLAN §5.6), **pure**: the branches
  `Core.Ingest.Extension.Normalize` and `Facts` take for those three sites.
  Each site's own members arrive nested under `indeed`, `yc` and
  `wellfound`, as the selector documents' dotted keys say.

  | Site | Money | Workplace | Details |
  |---|---|---|---|
  | `indeed` | `salary_text` with its period, as `platform_estimate` | `indeed.work_setting_text` ("Remote", "Hybrid work", "In person"), **but the description wins** when it says how (PLAN §5.6: the *remote* tag is applied loosely) | `job_indeed_details`: *Easily apply*, *Responsive employer*, *Urgently hiring*, the work setting |
  | `yc_waas` | `salary_text`, a year when no period is said (`parsed_text`); `yc.equity_text` → `equity_min_bp`/`equity_max_bp` | the location as written ("Remote (US)") | `job_yc_details`: the batch ("W24"), team size, stage, experience |
  | `wellfound` | `salary_text` (its equity half dropped), a year when no period is said; `wellfound.equity_text` (or the salary line's `%` half) → equity | `wellfound.remote_policy_text` | `job_wellfound_details`: stage, remote policy, time zones, visa |

  YC's and Wellfound's visa line is kept as written (`visa_text`) and read
  into `visa` only where it is plain: *will sponsor* → `yes`, *not
  available* / *no sponsorship* → `no`, *US citizen/visa only* →
  `existing_auth_only`; anything else stays unknown. A text nobody can read
  becomes nothing, never a guess.
  """

  alias Core.Ingest.Extension.{Money, Read}

  @sites [:indeed, :yc_waas, :wellfound]
  @members %{indeed: "indeed", yc_waas: "yc", wellfound: "wellfound"}

  @seasons %{"winter" => "W", "summer" => "S", "fall" => "F", "autumn" => "F", "spring" => "X"}

  @visa_no ~r/\b(no|not|won't|will not|doesn't|does not|unable)\b.*sponsor|not available|not offered|^no\b/i
  @visa_existing ~r/citizen|green card|existing|authori[sz]ed|\bonly\b/i
  @visa_yes ~r/sponsor|available|offered|^yes\b/i

  @doc "The sites this module reads."
  @spec sites() :: [atom()]
  def sites, do: @sites

  @doc "A site's own member of the fields (`indeed`, `yc`, `wellfound`), or `%{}`."
  @spec own(map(), atom()) :: map()
  def own(fields, site) when site in @sites, do: Read.sub(fields, Map.fetch!(@members, site))
  def own(_fields, _site), do: %{}

  # ── The job's columns ───────────────────────────────────────────────────────

  @doc """
  The employment text a site gives: Indeed's job type when the shared
  `employment_text` is missing.
  """
  @spec employment_text(atom(), map()) :: String.t() | nil
  def employment_text(:indeed, fields),
    do: Read.text(fields, "employment_text") || Read.text(own(fields, :indeed), "job_type_text")

  def employment_text(_site, fields), do: Read.text(fields, "employment_text")

  @doc """
  The words that say where the work is, for `Normalize.place/3`. On Indeed
  the description wins over the work-setting tag when it says how.

      iex> Core.Ingest.Extension.Sites.workplace_text(:indeed, %{"indeed" => %{"work_setting_text" => "Remote"}}, "This is an on-site role in Lahore.")
      "On-site"
      iex> Core.Ingest.Extension.Sites.workplace_text(:indeed, %{"indeed" => %{"work_setting_text" => "In person"}}, nil)
      "On-site"
  """
  @spec workplace_text(atom(), map(), String.t() | nil) :: String.t() | nil
  def workplace_text(:indeed, fields, plain) do
    described(plain) || setting(Read.text(own(fields, :indeed), "work_setting_text")) ||
      Read.text(fields, "workplace_text")
  end

  def workplace_text(:wellfound, fields, _plain),
    do:
      Read.text(own(fields, :wellfound), "remote_policy_text") ||
        Read.text(fields, "workplace_text")

  def workplace_text(_site, fields, _plain), do: Read.text(fields, "workplace_text")

  # Indeed's settings: "Remote", "Hybrid work", "In person" (on site).
  defp setting(nil), do: nil

  defp setting(text) do
    cond do
      text =~ ~r/hybrid/i -> "Hybrid"
      text =~ ~r/in[\s-]?person|on[\s-]?site|in[\s-]?office/i -> "On-site"
      text =~ ~r/remote/i -> "Remote"
      true -> text
    end
  end

  # What the description says of the place, when it says one thing.
  defp described(nil), do: nil

  defp described(plain) do
    hybrid? = plain =~ ~r/\bhybrid\b/i
    on_site? = plain =~ ~r/\b(on[\s-]?site|in[\s-]?office|in[\s-]?person|office[\s-]based)\b/i
    remote? = plain =~ ~r/\b(remote|work from home|wfh)\b/i

    cond do
      hybrid? -> "Hybrid"
      on_site? and not remote? -> "On-site"
      remote? and not on_site? -> "Remote"
      true -> nil
    end
  end

  @doc """
  The place as a site writes it: Indeed's "Remote in Karachi, Sindh" is
  the setting and then the place.

      iex> Core.Ingest.Extension.Sites.location_text(:indeed, "Hybrid remote in London")
      "London"
  """
  @spec location_text(atom(), String.t() | nil) :: String.t() | nil
  def location_text(:indeed, text) when is_binary(text) do
    text
    |> String.replace(~r/^(hybrid remote|hybrid work|hybrid|remote|in[\s-]?person)\s+in\s+/i, "")
    |> String.trim()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  def location_text(_site, text), do: text

  @doc """
  The money columns (`comp_*`) of a site's salary line: Indeed's as a
  `platform_estimate` with the period it says; YC's and Wellfound's as
  read, a year when no period is said.

      iex> Core.Ingest.Extension.Sites.money(:indeed, %{"salary_text" => "$25 an hour"})
      %{"comp_currency" => "USD", "comp_max_minor" => 2500, "comp_min_minor" => 2500, "comp_period" => "hour", "comp_source" => "platform_estimate", "comp_text" => "$25 an hour"}
  """
  @spec money(atom(), map()) :: map()
  def money(:indeed, fields) do
    case Money.salary(Read.text(fields, "salary_text")) do
      nil -> %{}
      salary -> Money.comp(salary.text, salary.period, "platform_estimate")
    end
  end

  def money(site, fields) when site in [:yc_waas, :wellfound] do
    case Read.text(fields, "salary_text") do
      nil ->
        %{}

      text ->
        case without_equity(text) do
          nil ->
            %{}

          said ->
            period = (Money.salary(said) || %{period: "year"}).period
            said |> Money.comp(period, "parsed_text") |> keep_text(text)
        end
    end
  end

  def money(_site, _fields), do: %{}

  defp keep_text(comp, _text) when comp == %{}, do: comp
  defp keep_text(comp, text), do: Map.put(comp, "comp_text", text)

  # "$140k – $180k • 0.5% – 1.0%": the money half, without the equity.
  defp without_equity(text) do
    text
    |> String.split(~r/[•·|]/u)
    |> Enum.reject(&(&1 =~ ~r/%/))
    |> Enum.join(" ")
    |> String.trim()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  @doc """
  The job's other columns a site says: the visa line as written and read,
  and the equity range in basis points. Only what was read.
  """
  @spec columns(atom(), map()) :: map()
  def columns(site, fields) when site in [:yc_waas, :wellfound] do
    mine = own(fields, site)
    visa_text = Read.text(mine, "visa_text")
    equity_text = Read.text(mine, "equity_text") || percent_half(Read.text(fields, "salary_text"))

    %{"visa_text" => visa_text, "visa" => visa(visa_text)}
    |> Map.merge(equity(equity_text))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def columns(_site, _fields), do: %{}

  defp percent_half(nil), do: nil

  defp percent_half(text) do
    text
    |> String.split(~r/[•·|]/u)
    |> Enum.find(&(&1 =~ ~r/%/))
    |> then(&(&1 && String.trim(&1)))
  end

  @doc """
  Equity as written into basis points (`equity_min_bp`, `equity_max_bp`):
  one percentage is both ends. Over 100% is no equity at all.

      iex> Core.Ingest.Extension.Sites.equity("0.25% – 1.00%")
      %{"equity_min_bp" => 25, "equity_max_bp" => 100}
      iex> Core.Ingest.Extension.Sites.equity("0.5%")
      %{"equity_min_bp" => 50, "equity_max_bp" => 50}
      iex> Core.Ingest.Extension.Sites.equity("No equity")
      %{}
  """
  @spec equity(String.t() | nil) :: map()
  def equity(nil), do: %{}

  def equity(text) do
    points =
      ~r/(\d+(?:\.\d+)?)\s*%/
      |> Regex.scan(text)
      |> Enum.take(2)
      |> Enum.map(fn [_all, n] -> n |> Decimal.new() |> Decimal.mult(100) |> Decimal.round(0) end)
      |> Enum.map(&Decimal.to_integer/1)

    case points do
      [] ->
        %{}

      all ->
        {low, high} = Enum.min_max(all)
        if high <= 10_000, do: %{"equity_min_bp" => low, "equity_max_bp" => high}, else: %{}
    end
  end

  @doc """
  A visa line read where it is plain, else `nil`.

      iex> Core.Ingest.Extension.Sites.visa("Will sponsor")
      "yes"
      iex> Core.Ingest.Extension.Sites.visa("US citizen/visa only")
      "existing_auth_only"
      iex> Core.Ingest.Extension.Sites.visa("Not available")
      "no"
      iex> Core.Ingest.Extension.Sites.visa("US citizenship/visa not required")
      nil
  """
  @spec visa(String.t() | nil) :: String.t() | nil
  def visa(nil), do: nil

  def visa(text) do
    cond do
      text =~ ~r/not required/i -> nil
      text =~ @visa_no -> "no"
      text =~ @visa_existing -> "existing_auth_only"
      text =~ @visa_yes -> "yes"
      true -> nil
    end
  end

  # ── The platform details ────────────────────────────────────────────────────

  @doc """
  A site's platform details (its `job_<site>_details` row), only what was
  read: Indeed's flags (`easy?` the apply method read, when the page sent
  no *Easily apply*), YC's batch and size, Wellfound's lines as written.
  """
  @spec details(atom(), map(), boolean() | nil) :: map()
  def details(:indeed, fields, easy?) do
    mine = own(fields, :indeed)

    %{
      is_easily_apply: flag(mine["easily_apply"]) || easy?,
      is_responsive_employer: flag(mine["responsive_employer"]),
      is_urgently_hiring: flag(mine["urgently_hiring"]),
      work_setting_text: short(Read.text(mine, "work_setting_text"))
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def details(:yc_waas, fields, _easy?) do
    mine = own(fields, :yc_waas)

    %{
      batch: batch(Read.text(mine, "batch_text")),
      team_size: team_size(Read.text(mine, "team_size_text")),
      stage_text: short(Read.text(mine, "stage_text")),
      experience_text: short(Read.text(mine, "experience_text"))
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def details(:wellfound, fields, _easy?) do
    mine = own(fields, :wellfound)

    %{
      company_stage_text: short(Read.text(mine, "stage_text")),
      remote_policy_text: short(Read.text(mine, "remote_policy_text")),
      timezone_text: short(Read.text(mine, "timezone_text")),
      visa_text: short(Read.text(mine, "visa_text"))
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def details(_site, _fields, _easy?), do: %{}

  defp flag(value) when is_boolean(value), do: value
  defp flag(_value), do: nil

  defp short(nil), do: nil
  defp short(text), do: String.slice(text, 0, 200)

  @doc """
  A YC batch as YC writes it ("W24", "YC S23", "Winter 2024"), or `nil`.

      iex> Core.Ingest.Extension.Sites.batch("YC W24")
      "W24"
      iex> Core.Ingest.Extension.Sites.batch("Summer 2023")
      "S23"
  """
  @spec batch(String.t() | nil) :: String.t() | nil
  def batch(nil), do: nil

  def batch(text) do
    case Regex.run(~r/\b([WSFX])\s?'?(\d{2})\b/i, text) do
      [_all, season, year] ->
        String.upcase(season) <> year

      nil ->
        case Regex.run(~r/\b(winter|summer|fall|autumn|spring)\s+'?(?:20)?(\d{2})\b/i, text) do
          [_all, season, year] -> Map.fetch!(@seasons, String.downcase(season)) <> year
          nil -> nil
        end
    end
  end

  @doc """
  A team size as written ("12 people", "Team size: 25"), or `nil`; of a
  band ("11-50") its lower end, so nothing is invented.

      iex> Core.Ingest.Extension.Sites.team_size("12 people")
      12
  """
  @spec team_size(String.t() | nil) :: pos_integer() | nil
  def team_size(text) do
    case Read.integer(text) do
      n when is_integer(n) and n >= 1 -> n
      _none -> nil
    end
  end
end
