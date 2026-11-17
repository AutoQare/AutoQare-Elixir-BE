defmodule Core.Behaviour.ZoneTest do
  @moduledoc """
  AQ-10 §6.3, pure: the Upwork client's local time, read against the
  capture's UTC time, into the zone of the client's country that has that
  offset now; failing that, `Etc/GMT±h`, or a zone off the whole hour.
  """

  use ExUnit.Case, async: true

  alias Core.Behaviour.Zone

  doctest Zone

  @at ~U[2026-11-14 10:41:30Z]

  test "every zone it may answer with is a zone this server knows" do
    for zone <- Zone.zones(), do: assert({:ok, _} = DateTime.now(zone), zone)
  end

  test "the country picks among its zones by the offset at the capture" do
    assert Zone.from_local_time("2:41 AM", "United States", @at) == "America/Los_Angeles"
    assert Zone.from_local_time("4:41 AM", "Chicago, United States", @at) == "America/Chicago"
    assert Zone.from_local_time("9:41 PM", "Sydney, Australia", @at) == "Australia/Sydney"
    assert Zone.from_local_time("11:41", "Germany", @at) == "Europe/Berlin"
    # Summer in Berlin is two hours on: UTC+1 in July is no German zone.
    assert Zone.from_local_time("11:41", "Germany", ~U[2026-07-14 10:41:30Z]) == "Etc/GMT-1"
  end

  test "no country, or none matching: Etc/GMT±h, Etc/UTC, or a zone off the hour" do
    assert Zone.from_local_time("6:41 AM", nil, @at) == "Etc/GMT+4"
    assert Zone.from_local_time("10:41 AM", "Atlantis", @at) == "Etc/UTC"
    assert Zone.from_local_time("4:11 PM", nil, @at) == "Asia/Kolkata"
    assert Zone.from_local_time("4:26 PM", nil, @at) == "Asia/Kathmandu"
  end

  test "a text nobody can read is nothing, never a guess" do
    assert Zone.from_local_time(nil, "Pakistan", @at) == nil
    assert Zone.from_local_time("13:61", "Pakistan", @at) == nil
    assert Zone.from_local_time("13:10 PM", "Pakistan", @at) == nil
    assert Zone.offset_minutes("12:41 AM", @at) == -600
    assert Zone.offset_minutes("12:11 PM", @at) == 90
  end
end
