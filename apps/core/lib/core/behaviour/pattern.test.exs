defmodule Core.Behaviour.PatternTest do
  @moduledoc """
  AQ-10 §7 and QP10-6, pure: a week of observations gives the sentence
  and the heat map the run expects, in both zones; too little says so;
  nothing seen says nothing.
  """

  use ExUnit.Case, async: true

  alias Core.Behaviour.Pattern

  doctest Pattern

  @now ~U[2026-11-14 10:00:00Z]
  @karachi "Asia/Karachi"

  # Tue, Wed and Thu, 09:00–12:59 UTC (14:00–17:59 in Karachi), twice each.
  @week for day <- 2..4, hour <- 9..12, do: {:active, day, hour, 2}
  # Three jobs on Mondays at noon in Karachi (07:00 UTC).
  @posted [{:posted, 1, 7, 3}]

  defp facts(attrs) do
    Map.merge(
      %{
        hours: [],
        last_active_at: nil,
        active_days: 0,
        delays: [],
        posted_recent: 0,
        seen: 0
      },
      attrs
    )
  end

  test "a week: the sentence, online first, then replies, then posting; the map in both zones" do
    facts =
      facts(%{
        hours: @week ++ @posted,
        active_days: 3,
        delays: [3600, 10_800, 14_400, 7200, 10_800],
        posted_recent: 3,
        last_active_at: ~U[2026-11-14 08:00:00Z],
        seen: 32
      })

    summary = Pattern.summary(facts, %{zone: @karachi, now: @now})

    assert summary.sentence ==
             "Usually online Tue–Thu 14:00–18:00 PKT · replies in about 3 h · posts on Mondays"

    assert summary.enough and summary.seen == 32
    assert summary.last_seen == %{at: ~U[2026-11-14 08:00:00Z], words: "Active 2 h ago"}
    assert summary.reply_delay == %{median_s: 10_800, words: "replies in about 3 h"}
    assert %{per_week: 0.3, weekday: 1, hour: nil, words: "posts on Mondays"} = summary.cadence

    ours = Pattern.heat(facts.hours, @karachi, @now)
    assert length(ours) == 7 and Enum.all?(ours, &(length(&1) == 24))
    # Tuesday 14:00 in Karachi holds Tuesday 09:00 UTC.
    assert ours |> Enum.at(1) |> Enum.at(14) == 2
    assert ours |> Enum.at(1) |> Enum.at(9) == 0
    assert ours |> Enum.map(&Enum.sum/1) == [0, 8, 8, 8, 0, 0, 0]

    # New York in November is UTC−5: the same hours read 04:00–07:59.
    theirs = Pattern.heat(facts.hours, "America/New_York", @now)
    assert theirs |> Enum.at(1) |> Enum.at(4) == 2
    assert theirs |> Enum.at(1) |> Enum.slice(4..7) == [2, 2, 2, 2]

    assert Pattern.online(facts.hours, 3, "America/New_York", @now) ==
             "Usually online Tue–Thu 04:00–08:00 EST"
  end

  test "posting's hour only from jobs first seen on their posting day" do
    seen = [~U[2026-11-02 05:10:00Z], ~U[2026-11-09 05:40:00Z], ~U[2026-10-26 05:20:00Z]]

    assert %{hour: 10, words: "posts on Mondays around 10:00"} =
             Pattern.cadence(@posted, 3, seen, @karachi, @now)

    assert %{hour: nil} = Pattern.cadence(@posted, 3, Enum.take(seen, 2), @karachi, @now)
  end

  test "posting without a usual day says how often" do
    spread = [{:posted, 1, 7, 1}, {:posted, 3, 7, 1}, {:posted, 5, 7, 1}]

    assert %{weekday: nil, words: "posted 3 jobs in 12 weeks"} =
             Pattern.cadence(spread, 3, [], @karachi, @now)

    many = for d <- 1..7, do: {:posted, d, 7, 4}

    assert %{per_week: 2.3, words: "posts about 2.3 jobs a week"} =
             Pattern.cadence(many, 28, [], @karachi, @now)

    assert Pattern.cadence([{:posted, 1, 7, 2}], 2, [], @karachi, @now) == nil
  end

  test "QP10-6: online needs 5 on 3 days, replies 3, posting 3; below, not enough" do
    two_days = for day <- 2..3, hour <- 9..11, do: {:active, day, hour, 1}

    assert Pattern.online(two_days, 2, @karachi, @now) == nil
    # Three days the kept observations fall on count, though the cells hold two weekdays.
    assert Pattern.online(two_days, 3, @karachi, @now) =~ "Usually online"

    few = facts(%{hours: [{:active, 2, 9, 2}, {:replied, 2, 9, 1}], delays: [60, 120], seen: 3})
    summary = Pattern.summary(few, %{zone: @karachi, now: @now})

    assert summary.sentence == "Not enough seen yet: 3 observations."
    refute summary.enough
    assert summary.reply_delay == nil and summary.cadence == nil

    nothing = Pattern.summary(facts(%{}), %{zone: @karachi, now: @now})
    assert nothing.sentence == nil and nothing.seen == 0 and nothing.last_seen == nil
    assert Pattern.sentence([], 1) == "Not enough seen yet: 1 observation."
  end

  test "days across the week's end are one run; scattered days are a list; all seven, every day" do
    weekend = for day <- [6, 7, 1], do: {:active, day, 20, 3}
    assert Pattern.online(weekend, 3, "Etc/UTC", @now) == "Usually online Sat–Mon 20:00–21:00 UTC"

    scattered = for day <- [1, 3, 5], do: {:active, day, 20, 3}
    assert Pattern.online(scattered, 3, "Etc/UTC", @now) =~ "Mon, Wed, Fri 20:00–21:00"

    all = for day <- 1..7, hour <- 0..23, do: {:active, day, hour, 1}
    assert Pattern.online(all, 7, "Etc/UTC", @now) == "Usually online every day UTC"
  end

  test "last seen: now, minutes, hours, a weekday within a week, then a date" do
    words = &Pattern.last_seen(&1, @now, @karachi).words

    assert words.(~U[2026-11-14 09:55:00Z]) == "Active now"
    assert words.(~U[2026-11-14 09:35:00Z]) == "Active 25 min ago"
    assert words.(~U[2026-11-13 12:00:00Z]) == "Active 22 h ago"
    # Tuesday 09:10 UTC is 14:10 in Karachi.
    assert words.(~U[2026-11-10 09:10:00Z]) == "Last seen Tue 14:10"
    assert words.(~U[2026-11-03 09:10:00Z]) == "Last seen 3 Nov"
    assert words.(~U[2025-12-24 09:10:00Z]) == "Last seen 24 Dec 2025"
  end

  test "reply delays in words: minutes, hours, the same day, days; the median of the last 20" do
    assert Pattern.delay_words(30) == "replies in about 1 min"
    assert Pattern.delay_words(8 * 3600) == "replies in about 8 h"
    assert Pattern.delay_words(86_400) == "replies the same day"
    assert Pattern.delay_words(36 * 3600) == "replies in about 2 days"
    assert Pattern.delay_words(30 * 3600) == "replies in about a day"

    # The 21st (an outlier, the oldest) is not read.
    delays = List.duplicate(600, 20) ++ [999_999]
    assert Pattern.reply_delay(delays) == %{median_s: 600, words: "replies in about 10 min"}

    assert Pattern.reply_delay([600, 1200, 1800, 2400]) == %{
             median_s: 1500,
             words: "replies in about 25 min"
           }
  end

  test "an offset off the hour is rounded; an unknown zone reads as UTC" do
    assert Pattern.offset_hours("Asia/Kolkata", @now) == 6
    assert Pattern.offset_hours("America/St_Johns", @now) == -3
    assert Pattern.offset_hours("Nowhere/Else", @now) == 0
    assert Pattern.abbreviation(@karachi, @now) == "PKT"
  end
end
