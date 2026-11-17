defmodule Core.Ingest.Extension.Facts do
  @moduledoc """
  The platforms' own facts (AQ-05 §10.1), **pure**: LinkedIn's applicants
  and flags and Upwork's client lines as the job's platform details
  (`job_linkedin_details`, `job_upwork_details`; AQ-12: Indeed's, YC's and
  Wellfound's from `Core.Ingest.Extension.Sites`), and what moves — the
  applicants, the proposals, the interviews, the invites, the hires, when
  the client last looked — as the signals (`job_signals`). Only what was
  read is set.
  """

  alias Core.Ingest.Extension.{Money, Read, Sites}

  @experience [
    {~r/^entry/i, :entry},
    {~r/^intermediate/i, :intermediate},
    {~r/^expert/i, :expert}
  ]
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc """
  The source's details: LinkedIn's from the fields and the apply method
  read (`easy?`), Upwork's from its `upwork` and `upwork.client` members;
  Indeed's, YC's and Wellfound's `Sites.details/3`; nothing for a site
  without a table.
  """
  @spec details(atom(), map(), boolean() | nil) :: map()
  def details(:linkedin, fields, easy?) do
    {count, capped} = applicants(Read.text(fields, "applicants_text"))

    %{
      is_easy_apply: easy?,
      applicant_count: count,
      is_applicant_count_capped: count && capped,
      is_promoted: if(is_boolean(fields["is_promoted"]), do: fields["is_promoted"]),
      experience_level_text: Read.text(fields, "seniority_text"),
      employment_status_text: Read.text(fields, "employment_text"),
      hiring_team_text: Read.text(fields, "hiring_team_text")
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def details(:upwork, fields, _easy?) do
    upwork = Read.sub(fields, "upwork")

    upwork
    |> Read.sub("client")
    |> client()
    |> Map.merge(%{
      experience_level: experience(Read.text(upwork, "experience_text")),
      connects_required: Read.integer(Read.text(upwork, "connects_text"))
    })
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  def details(site, fields, easy?) when site in [:indeed, :yc_waas, :wellfound],
    do: Sites.details(site, fields, easy?)

  def details(_site, _fields, _easy?), do: %{}

  defp client(client) do
    avg = client |> Read.text("avg_rate_text") |> Money.bid()
    spent = Read.text(client, "spent_text")
    count = &client_count(Read.text(client, &1), &2)

    %{
      is_client_payment_verified: verified(client["payment_verified"]),
      client_rating: rating(Read.text(client, "rating_text")),
      client_reviews: count.("reviews_text", :reviews),
      client_country: client |> Read.text("location_text") |> country(),
      client_jobs_posted: count.("jobs_posted_text", :jobs_posted),
      client_hire_rate_pct: percent(Read.text(client, "hire_rate_text")),
      client_open_jobs: count.("open_jobs_text", :open_jobs),
      client_spent_band: spent && Money.spent_band(spent),
      client_hires: count.("hires_text", :hires),
      client_active_hires: count.("active_hires_text", :active_hires),
      client_avg_hourly_minor: avg && avg.bid_minor,
      client_avg_hourly_currency: avg && avg.bid_currency,
      client_member_since_on: member_since(Read.text(client, "member_since_text"))
    }
  end

  # AQ-12C B16: each of the client's counts is the number right before its
  # own words. A number that is the tail of a decimal ("4.81") is no count.
  @count_words %{
    reviews: ~r/(?<![\d.,])(\d[\d,]*)\s+reviews?\b/i,
    open_jobs: ~r/(?<![\d.,])(\d[\d,]*)\s+open\s+jobs?\b/i,
    jobs_posted: ~r/(?<![\d.,])(\d[\d,]*)\s+jobs?\s+posted\b/i,
    hires: ~r/(?<![\d.,])(\d[\d,]*)\s+hires?\b(?!\s+rate)/i,
    active_hires: ~r/(?<![\d.,])(\d[\d,]*)\s+active\b/i
  }

  @doc """
  One of Upwork's client counts (AQ-12C B16): the number next to its own
  words — reviews before "review", open jobs before "open job", jobs posted
  before "job(s) posted", hires before "hire" (not "hire rate"), active
  hires before "active". A text that is only a number is that number; one
  with neither is nothing, since a wrong number is worse than none.

      iex> Core.Ingest.Extension.Facts.client_count("4.81 of 22 reviews", :reviews)
      22
      iex> Core.Ingest.Extension.Facts.client_count("70% hire rate, 1 open job", :open_jobs)
      1
      iex> Core.Ingest.Extension.Facts.client_count("9 jobs posted", :jobs_posted)
      9
      iex> Core.Ingest.Extension.Facts.client_count("7 hires, 2 active", :hires)
      7
      iex> Core.Ingest.Extension.Facts.client_count("7 hires, 2 active", :active_hires)
      2
      iex> Core.Ingest.Extension.Facts.client_count("70 hire rate", :hires)
      nil
      iex> Core.Ingest.Extension.Facts.client_count(" 1,204 ", :reviews)
      1204
      iex> Core.Ingest.Extension.Facts.client_count("70% hire rate", :open_jobs)
      nil
  """
  @spec client_count(String.t() | nil, atom()) :: non_neg_integer() | nil
  def client_count(nil, _count), do: nil

  def client_count(text, count) do
    lone = Regex.run(~r/^\s*(\d[\d,]*)\s*$/, text, capture: :all_but_first)
    near = Regex.run(Map.fetch!(@count_words, count), text, capture: :all_but_first)

    case near || lone do
      [digits] -> digits |> String.replace(",", "") |> String.to_integer()
      nil -> nil
    end
  end

  @doc """
  Upwork's experience level.

      iex> Core.Ingest.Extension.Facts.experience("Intermediate")
      :intermediate
  """
  @spec experience(String.t() | nil) :: atom() | nil
  def experience(nil), do: nil
  def experience(text), do: Read.first_match(String.trim_leading(text), @experience)

  defp verified(value) when is_boolean(value), do: value

  defp verified(text) when is_binary(text) do
    cond do
      text =~ ~r/unverified|not verified/i -> false
      text =~ ~r/verified/i -> true
      true -> nil
    end
  end

  defp verified(_none), do: nil

  defp rating(nil), do: nil

  defp rating(text) do
    with [value] <- Regex.run(~r/\d(?:\.\d+)?/, text),
         rating = Decimal.new(value),
         false <- Decimal.compare(rating, 5) == :gt do
      Decimal.round(rating, 2)
    else
      _no -> nil
    end
  end

  defp percent(nil), do: nil

  defp percent(text) do
    case Regex.run(~r/(\d{1,3})\s*%/, text) do
      [_all, n] -> n |> String.to_integer() |> min(100)
      nil -> nil
    end
  end

  defp country(nil), do: nil
  defp country(text), do: text |> Read.countries() |> List.first()

  defp member_since(nil), do: nil

  defp member_since(text) do
    with [_all, month, day, year] <-
           Regex.run(~r/([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})/, text),
         i when is_integer(i) <- Enum.find_index(@months, &(&1 == String.downcase(month))),
         {:ok, on} <- Date.new(String.to_integer(year), i + 1, String.to_integer(day)) do
      on
    else
      _bad -> nil
    end
  end

  # ── The signals ─────────────────────────────────────────────────────────────

  @doc """
  LinkedIn's applicants: `{count, capped?}`.

      iex> Core.Ingest.Extension.Facts.applicants("Over 100 applicants")
      {100, true}
      iex> Core.Ingest.Extension.Facts.applicants("37 applicants")
      {37, false}
  """
  @spec applicants(String.t() | nil) :: {non_neg_integer() | nil, boolean()}
  def applicants(nil), do: {nil, false}

  def applicants(text) do
    cond do
      text =~ ~r/be among the first/i -> {nil, false}
      text =~ ~r/over|more than|\+/i -> {Read.integer(text), true}
      true -> {Read.integer(text), false}
    end
  end

  @doc """
  Upwork's proposals band: `{min, max}`, `max` `nil` for "50+", 0 to 5 for
  "Less than 5".

      iex> Core.Ingest.Extension.Facts.proposals("Less than 5")
      {0, 5}
      iex> Core.Ingest.Extension.Facts.proposals("50+")
      {50, nil}
  """
  @spec proposals(String.t() | nil) :: {non_neg_integer() | nil, non_neg_integer() | nil}
  def proposals(nil), do: {nil, nil}

  def proposals(text) do
    cond do
      match = Regex.run(~r/less than\s+(\d+)/i, text) ->
        {0, String.to_integer(Enum.at(match, 1))}

      match = Regex.run(~r/(\d+)\s*(?:to|-|–)\s*(\d+)/i, text) ->
        [_all, min, max] = match
        {String.to_integer(min), String.to_integer(max)}

      match = Regex.run(~r/(\d+)\s*\+/, text) ->
        {String.to_integer(Enum.at(match, 1)), nil}

      true ->
        {nil, nil}
    end
  end

  @doc """
  The signals a capture read, with `slack_s` (how precisely
  `client_last_viewed_at` was said), or `nil` when it read none.
  """
  @spec signal(map(), DateTime.t()) :: map() | nil
  def signal(fields, now) do
    upwork = Read.sub(fields, "upwork")
    count = &Read.integer(Read.text(upwork, &1))
    {applicants, capped} = applicants(Read.text(fields, "applicants_text"))
    {min, max} = proposals(Read.text(upwork, "proposals_text"))
    viewed = upwork |> Read.text("last_viewed_text") |> then(&(&1 && Read.ago(&1, now)))

    facts = %{
      applicant_count: applicants,
      is_applicant_count_capped: applicants && capped,
      proposals_min: min,
      proposals_max: max,
      interviewing: count.("interviewing_text"),
      invites_sent: count.("invites_text"),
      unanswered_invites: count.("unanswered_text"),
      hires: count.("hires_text"),
      client_last_viewed_at: viewed && elem(viewed, 0)
    }

    if Enum.all?(Map.values(facts), &is_nil/1),
      do: nil,
      else: Map.put(facts, :slack_s, if(viewed, do: elem(viewed, 1), else: 0))
  end
end
