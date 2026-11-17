defmodule Utils.Days do
  @moduledoc """
  Calendar days in a zone, **pure**: the one copy the dashboards' windows
  (`Core.Dashboards.Windows`) and the lists' date filters (`Data.Filters`)
  both read, so a tile and the list it opens agree on what *today* is.
  Both ends of a window are built from dates (`DateTime.new/4`), never by
  adding seconds, so a day a clock change makes 23 or 25 hours long is
  still one day.

  A window is `{from, to}` in UTC, `to` exclusive.
  """

  @doc "The calendar day of `now` in `zone` (UTC's for a zone it can't read)."
  @spec today(DateTime.t(), String.t()) :: Date.t()
  def today(%DateTime{} = now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _unknown} -> DateTime.to_date(now)
    end
  end

  @doc """
  The first instant of `on` in `zone`, in UTC. A midnight that a clock
  change skips starts when the day does; one it repeats, at the first.

      iex> Utils.Days.start_of(~D[2026-03-29], "Europe/London")
      ~U[2026-03-29 00:00:00.000000Z]
      iex> Utils.Days.start_of(~D[2026-03-30], "Europe/London")
      ~U[2026-03-29 23:00:00.000000Z]
  """
  @spec start_of(Date.t(), String.t()) :: DateTime.t()
  def start_of(%Date{} = on, zone) do
    case DateTime.new(on, ~T[00:00:00.000000], zone) do
      {:ok, at} -> utc(at)
      {:gap, _before, at} -> utc(at)
      {:ambiguous, at, _later} -> utc(at)
      {:error, _reason} -> DateTime.new!(on, ~T[00:00:00.000000], "Etc/UTC")
    end
  end

  @doc "The window from the start of `first` to the start of the day after `last`, in `zone`."
  @spec window(Date.t(), Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def window(%Date{} = first, %Date{} = last, zone),
    do: {start_of(first, zone), start_of(Date.add(last, 1), zone)}

  # Microseconds always at full precision, as the columns hold them.
  defp utc(at) do
    %{microsecond: {us, _p}} = utc = DateTime.shift_zone!(at, "Etc/UTC")
    %{utc | microsecond: {us, 6}}
  end
end
