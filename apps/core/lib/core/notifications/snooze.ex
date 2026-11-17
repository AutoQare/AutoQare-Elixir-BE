defmodule Core.Notifications.Snooze do
  @moduledoc """
  *Pause notifications* (AQ-10B §6, §11.4, QP10b-3): until when. **Pure**:
  the choice, the moment and the person's zone in, an instant out.

  - `hour`: an hour from now;
  - `tomorrow`: tomorrow at 08:00 where the person is;
  - `monday`: the coming Monday at 08:00 where the person is (from a
    Monday, the next one);
  - `null`: no snooze.

  Calendar days, never `+ 86_400`: the day the clocks change is 23 or 25
  hours long.
  """

  @at ~T[08:00:00]

  @doc """
  The instant a choice snoozes until, `{:ok, nil}` for none, or a field
  error.

      iex> Core.Notifications.Snooze.until("hour", ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      {:ok, ~U[2026-11-14 11:00:00Z]}
      iex> Core.Notifications.Snooze.until("tomorrow", ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      {:ok, ~U[2026-11-15 03:00:00Z]}
      iex> Core.Notifications.Snooze.until("monday", ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      {:ok, ~U[2026-11-16 03:00:00Z]}
      iex> Core.Notifications.Snooze.until(nil, ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      {:ok, nil}
  """
  @spec until(String.t() | nil, DateTime.t(), String.t() | nil) ::
          {:ok, DateTime.t() | nil} | {:error, term()}
  def until(nil, _now, _zone), do: {:ok, nil}
  def until("hour", %DateTime{} = now, _zone), do: {:ok, DateTime.add(now, 3600, :second)}

  def until("tomorrow", %DateTime{} = now, zone) do
    today = local_date(now, zone)
    {:ok, at_local(Date.add(today, 1), zone)}
  end

  def until("monday", %DateTime{} = now, zone) do
    today = local_date(now, zone)
    ahead = rem(8 - Date.day_of_week(today), 7)
    days = if ahead == 0, do: 7, else: ahead
    {:ok, at_local(Date.add(today, days), zone)}
  end

  def until(_other, _now, _zone),
    do: {:error, {:invalid, %{"for" => ["is hour, tomorrow, monday or null"]}}}

  defp local_date(now, zone) do
    case DateTime.shift_zone(now, zone || "Etc/UTC") do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(now)
    end
  end

  defp at_local(date, zone) do
    naive = NaiveDateTime.new!(date, @at)

    case DateTime.from_naive(naive, zone || "Etc/UTC") do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      _error -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
end
