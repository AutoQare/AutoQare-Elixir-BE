defmodule Core.Behaviour.Pattern do
  @moduledoc """
  What a subject's observations say (AQ-10 §7, QP10-6, QP10-19), **pure**:
  the facts `Data.Behaviour.facts/2` reads and the zones in, the heat map,
  *last seen*, the reply delay, the posting cadence and the one sentence
  out. Computed on read; nothing is cached. No forecast: it says what was
  seen.

  - **The heat map:** the `active` group's hour counts as 7 × 24, Monday
    first, hour 0 first, shifted from UTC by the zone's offset now
    (rounded to the hour), in our zone and, when the subject has one, in
    theirs.
  - **Online** (enough with 5 observations on 3 different days): the
    usual days are those holding at least half the busiest day's count;
    the usual hours, the run around the busiest hour of those days that
    holds at least half its count. In our zone: "Usually online Tue–Thu
    14:00–18:00 PKT".
  - **Replies** (enough with 3): the median of the last 20 delays, "replies
    in about 3 h"; past 8 h "replies the same day"; past a day "replies in
    about 2 days".
  - **Posting** (enough with 3 jobs): jobs a week over the last 12 weeks;
    the usual weekday from the `posted` group (at least 2, more than any
    other day); the hour only from jobs the extension first saw on the
    day they were posted (at least 3 such jobs, the commonest hour at
    least twice). "posts on Mondays around 10:00".
  - **Last seen:** the newest `active_at`: "Active now" (10 min), "Active
    25 min ago", "Active 2 h ago" within a day, then "Last seen Tue 14:10"
    within a week, then "Last seen 3 Nov".
  - **The sentence** joins the parts with enough, online first; with none,
    "Not enough seen yet: 3 observations."; with nothing seen, `nil`.
  """

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @plural ~w(Mondays Tuesdays Wednesdays Thursdays Fridays Saturdays Sundays)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @online_seen 5
  @online_days 3
  @replies_seen 3
  @posted_seen 3

  @typedoc "One hour cell, as stored: `{group, weekday 1–7, UTC hour, count}`."
  @type cell :: {atom(), 1..7, 0..23, non_neg_integer()}

  # ── The summary ─────────────────────────────────────────────────────────────

  @doc """
  The behaviour summary (AQ-10 §11.4) from a subject's facts:
  `%{sentence, enough, seen, last_seen, reply_delay, cadence}`. `opts`:
  `zone` (ours), `now`, `first_seen` (a company's same-day first sightings,
  for the posting hour).
  """
  @spec summary(map(), map()) :: map()
  def summary(facts, %{zone: zone, now: now} = opts) do
    online = online(facts.hours, facts.active_days, zone, now)
    replies = reply_delay(facts.delays)
    cadence = cadence(facts.hours, facts.posted_recent, Map.get(opts, :first_seen, []), zone, now)
    parts = Enum.reject([online, replies && replies.words, cadence && cadence.words], &is_nil/1)

    %{
      sentence: sentence(parts, facts.seen),
      enough: parts != [],
      seen: facts.seen,
      last_seen: last_seen(facts.last_active_at, now, zone),
      reply_delay: replies,
      cadence: cadence
    }
  end

  @doc """
  The parts joined, first letter up; "Not enough seen yet" without one.

      iex> Core.Behaviour.Pattern.sentence(["replies in about 3 h", "posts on Mondays"], 9)
      "Replies in about 3 h · posts on Mondays"
      iex> Core.Behaviour.Pattern.sentence([], 3)
      "Not enough seen yet: 3 observations."
      iex> Core.Behaviour.Pattern.sentence([], 0)
      nil
  """
  @spec sentence([String.t()], non_neg_integer()) :: String.t() | nil
  def sentence([], 0), do: nil
  def sentence([], 1), do: "Not enough seen yet: 1 observation."
  def sentence([], seen), do: "Not enough seen yet: #{seen} observations."

  def sentence(parts, _seen) do
    <<first::utf8, rest::binary>> = Enum.join(parts, " · ")
    String.upcase(<<first::utf8>>) <> rest
  end

  # ── The heat map ────────────────────────────────────────────────────────────

  @doc """
  A group's cells as 7 × 24 counts in `zone`, Monday first, hour 0 first:
  each UTC cell moved by the zone's offset at `now`, rounded to the hour.

      iex> grid = Core.Behaviour.Pattern.heat([{:active, 1, 23, 4}], "Asia/Karachi", ~U[2026-11-14 10:00:00Z])
      iex> grid |> Enum.at(1) |> Enum.at(4)
      4
  """
  @spec heat([cell()], String.t(), DateTime.t(), atom()) :: [[non_neg_integer()]]
  def heat(cells, zone, %DateTime{} = now, group \\ :active) do
    shift = offset_hours(zone, now)

    counts =
      for {^group, day, hour, count} <- cells, reduce: %{} do
        acc ->
          i = Integer.mod((day - 1) * 24 + hour + shift, 168)
          Map.update(acc, i, count, &(&1 + count))
      end

    for d <- 0..6, do: for(h <- 0..23, do: Map.get(counts, d * 24 + h, 0))
  end

  @doc "The zone's offset from UTC at `now`, in whole hours (rounded); 0 for an unknown zone."
  @spec offset_hours(String.t(), DateTime.t()) :: integer()
  def offset_hours(zone, now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> Integer.floor_div(local.utc_offset + local.std_offset + 1800, 3600)
      {:error, _unknown} -> 0
    end
  end

  @doc ~s|The zone's short name at `now` ("PKT", "CET", "+05"), or the zone itself.|
  @spec abbreviation(String.t(), DateTime.t()) :: String.t()
  def abbreviation(zone, now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> local.zone_abbr
      {:error, _unknown} -> zone
    end
  end

  # ── Online ──────────────────────────────────────────────────────────────────

  @doc """
  "Usually online Tue–Thu 14:00–18:00 PKT", or `nil` below 5 active
  observations on 3 different days (`active_days`: the distinct days the
  kept observations fall on; the cells' distinct weekdays count too, so the
  sentence outlives the observations).
  """
  @spec online([cell()], non_neg_integer(), String.t(), DateTime.t()) :: String.t() | nil
  def online(cells, active_days, zone, now) do
    grid = heat(cells, zone, now)
    totals = Enum.map(grid, &Enum.sum/1)
    seen = Enum.sum(totals)
    days = max(active_days, Enum.count(totals, &(&1 > 0)))

    if seen >= @online_seen and days >= @online_days do
      usual = usual_days(totals)
      hours = usual |> Enum.map(&Enum.at(grid, &1)) |> Enum.zip_with(&Enum.sum/1)
      words = Enum.join(Enum.reject([days_words(usual), hours_words(hours)], &is_nil/1), " ")
      "Usually online #{words} #{abbreviation(zone, now)}"
    end
  end

  defp usual_days(totals) do
    top = Enum.max(totals)
    for {n, d} <- Enum.with_index(totals), n > 0, n * 2 >= top, do: d
  end

  defp days_words(days) when length(days) == 7, do: "every day"

  # One run of days on the week's circle ("Tue–Thu", "Sat–Mon"), else a list.
  defp days_words(days) do
    set = MapSet.new(days)
    gap = Enum.find(0..6, &(not MapSet.member?(set, &1)))
    ordered = for i <- 1..7, d = Integer.mod(gap + i, 7), MapSet.member?(set, d), do: d

    contiguous? =
      ordered
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> b == Integer.mod(a + 1, 7) end)

    cond do
      length(ordered) == 1 -> Enum.at(@days, hd(ordered))
      contiguous? -> "#{Enum.at(@days, hd(ordered))}–#{Enum.at(@days, List.last(ordered))}"
      true -> Enum.map_join(Enum.sort(days), ", ", &Enum.at(@days, &1))
    end
  end

  # The hours around the busiest that hold at least half its count; `nil`
  # when that is the whole day.
  defp hours_words(hours) do
    top = Enum.max(hours)
    peak = Enum.find_index(hours, &(&1 == top))
    keep? = fn h -> Enum.at(hours, Integer.mod(h, 24)) * 2 >= top end
    first = walk(peak, -1, keep?)
    last = walk(peak, 1, keep?)

    if last - first >= 23,
      do: nil,
      else: "#{clock(Integer.mod(first, 24))}–#{clock(Integer.mod(last + 1, 24))}"
  end

  defp walk(from, step, keep?) do
    Enum.reduce_while(1..23, from, fn i, at ->
      if keep?.(from + i * step), do: {:cont, from + i * step}, else: {:halt, at}
    end)
  end

  defp clock(hour), do: String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"

  # ── Replies ─────────────────────────────────────────────────────────────────

  @doc """
  The median of the delays given (the last 20, newest first) with its
  words, or `nil` below 3.

      iex> Core.Behaviour.Pattern.reply_delay([3600, 10_800, 14_400])
      %{median_s: 10_800, words: "replies in about 3 h"}
      iex> Core.Behaviour.Pattern.reply_delay([60, 120])
      nil
  """
  @spec reply_delay([non_neg_integer()]) :: map() | nil
  def reply_delay(delays) when length(delays) < @replies_seen, do: nil

  def reply_delay(delays) do
    median = median(Enum.take(delays, 20))
    %{median_s: median, words: delay_words(median)}
  end

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: div(Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2)), 2)
  end

  @doc """
  A delay in words.

      iex> Core.Behaviour.Pattern.delay_words(1500)
      "replies in about 25 min"
      iex> Core.Behaviour.Pattern.delay_words(9 * 3600)
      "replies the same day"
      iex> Core.Behaviour.Pattern.delay_words(2 * 86_400)
      "replies in about 2 days"
  """
  @spec delay_words(non_neg_integer()) :: String.t()
  def delay_words(s) when s < 3600, do: "replies in about #{max(1, round(s / 60))} min"
  def delay_words(s) when s <= 8 * 3600, do: "replies in about #{round(s / 3600)} h"
  def delay_words(s) when s <= 86_400, do: "replies the same day"

  def delay_words(s) do
    case round(s / 86_400) do
      1 -> "replies in about a day"
      n -> "replies in about #{n} days"
    end
  end

  # ── Posting ─────────────────────────────────────────────────────────────────

  @doc """
  `%{per_week, weekday, hour, words}` (weekday 1–7 in `zone`, hour 0–23),
  or `nil` below 3 posted jobs. `recent` is the posted observations of the
  last 12 weeks; `first_seen` the same-day first sightings.
  """
  @spec cadence([cell()], non_neg_integer(), [DateTime.t()], String.t(), DateTime.t()) ::
          map() | nil
  def cadence(cells, recent, first_seen, zone, now) do
    totals = cells |> heat(zone, now, :posted) |> Enum.map(&Enum.sum/1)

    if Enum.sum(totals) >= @posted_seen do
      weekday = clear_top(totals, 2)
      hour = if length(first_seen) >= 3, do: first_seen |> local_hours(zone) |> clear_top(2)
      per_week = Float.round(recent / 12, 1)

      %{
        per_week: per_week,
        weekday: weekday && weekday + 1,
        hour: hour,
        words: cadence_words(weekday, hour, per_week, recent)
      }
    end
  end

  defp local_hours(instants, zone) do
    counts =
      Enum.frequencies_by(instants, fn at ->
        case DateTime.shift_zone(at, zone) do
          {:ok, local} -> local.hour
          {:error, _unknown} -> at.hour
        end
      end)

    for h <- 0..23, do: Map.get(counts, h, 0)
  end

  # The index of the largest count when it is at least `min` and larger
  # than every other; `nil` otherwise.
  defp clear_top(counts, min) do
    case counts |> Enum.with_index() |> Enum.sort_by(&elem(&1, 0), :desc) do
      [{top, i}, {second, _j} | _rest] when top >= min and top > second -> i
      [{top, i}] when top >= min -> i
      _tie -> nil
    end
  end

  defp cadence_words(weekday, hour, per_week, recent) do
    cond do
      weekday && hour -> "posts on #{Enum.at(@plural, weekday)} around #{clock(hour)}"
      weekday -> "posts on #{Enum.at(@plural, weekday)}"
      per_week >= 1 -> "posts about #{number(per_week)} jobs a week"
      recent > 0 -> "posted #{recent} #{if recent == 1, do: "job", else: "jobs"} in 12 weeks"
      true -> "no jobs in the last 12 weeks"
    end
  end

  defp number(f) when f == trunc(f), do: Integer.to_string(trunc(f))
  defp number(f), do: Float.to_string(f)

  # ── Last seen ───────────────────────────────────────────────────────────────

  @doc """
  `%{at, words}` for the newest active moment, or `nil`.

      iex> Core.Behaviour.Pattern.last_seen(~U[2026-11-14 08:00:00Z], ~U[2026-11-14 10:00:00Z], "Etc/UTC")
      %{at: ~U[2026-11-14 08:00:00Z], words: "Active 2 h ago"}
      iex> Core.Behaviour.Pattern.last_seen(~U[2026-11-10 14:10:00Z], ~U[2026-11-14 10:00:00Z], "Etc/UTC")
      %{at: ~U[2026-11-10 14:10:00Z], words: "Last seen Tue 14:10"}
  """
  @spec last_seen(DateTime.t() | nil, DateTime.t(), String.t()) :: map() | nil
  def last_seen(nil, _now, _zone), do: nil
  def last_seen(at, now, zone), do: %{at: at, words: seen_words(at, now, zone)}

  defp seen_words(at, now, zone) do
    ago = DateTime.diff(now, at, :second)
    local = local(at, zone)

    cond do
      ago < 600 ->
        "Active now"

      ago < 3600 ->
        "Active #{div(ago, 60)} min ago"

      ago < 86_400 ->
        "Active #{div(ago, 3600)} h ago"

      ago < 7 * 86_400 ->
        "Last seen #{Enum.at(@days, Date.day_of_week(local) - 1)} #{hhmm(local)}"

      local.year == local(now, zone).year ->
        "Last seen #{local.day} #{month(local)}"

      true ->
        "Last seen #{local.day} #{month(local)} #{local.year}"
    end
  end

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      {:error, _unknown} -> at
    end
  end

  defp hhmm(at), do: at |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 5)
  defp month(at), do: Enum.at(@months, at.month - 1)
end
