defmodule Core.Behaviour.Zone do
  @moduledoc """
  An Upwork client's local time as a company's time zone (AQ-10 §6.3,
  QP10-7), **pure**. The client's *local time* text ("3:42 PM", read on
  every capture) is read against the capture's UTC time into an offset,
  rounded to 15 minutes; then into the IANA zone of the client's country
  (the location text, by `Core.Ingest.Extension.Read.countries/1`) that
  has that offset at that moment; failing that, `Etc/GMT±h` for a whole
  hour (`Etc/UTC` for none), or a known zone for a half or quarter hour.
  A text nobody can read is `nil`, never a guess.
  """

  alias Core.Ingest.Extension.Read

  @by_country %{
    "US" => ~w(America/New_York America/Chicago America/Denver America/Phoenix
               America/Los_Angeles America/Anchorage Pacific/Honolulu),
    "CA" => ~w(America/Toronto America/Winnipeg America/Edmonton America/Vancouver
               America/Halifax America/St_Johns America/Regina),
    "GB" => ~w(Europe/London),
    "IE" => ~w(Europe/Dublin),
    "PT" => ~w(Europe/Lisbon Atlantic/Azores),
    "ES" => ~w(Europe/Madrid Atlantic/Canary),
    "FR" => ~w(Europe/Paris),
    "BE" => ~w(Europe/Brussels),
    "NL" => ~w(Europe/Amsterdam),
    "DE" => ~w(Europe/Berlin),
    "CH" => ~w(Europe/Zurich),
    "AT" => ~w(Europe/Vienna),
    "IT" => ~w(Europe/Rome),
    "DK" => ~w(Europe/Copenhagen),
    "NO" => ~w(Europe/Oslo),
    "SE" => ~w(Europe/Stockholm),
    "FI" => ~w(Europe/Helsinki),
    "PL" => ~w(Europe/Warsaw),
    "CZ" => ~w(Europe/Prague),
    "HU" => ~w(Europe/Budapest),
    "HR" => ~w(Europe/Zagreb),
    "RS" => ~w(Europe/Belgrade),
    "RO" => ~w(Europe/Bucharest),
    "BG" => ~w(Europe/Sofia),
    "GR" => ~w(Europe/Athens),
    "EE" => ~w(Europe/Tallinn),
    "LV" => ~w(Europe/Riga),
    "LT" => ~w(Europe/Vilnius),
    "UA" => ~w(Europe/Kyiv),
    "TR" => ~w(Europe/Istanbul),
    "IL" => ~w(Asia/Jerusalem),
    "EG" => ~w(Africa/Cairo),
    "SA" => ~w(Asia/Riyadh),
    "QA" => ~w(Asia/Qatar),
    "AE" => ~w(Asia/Dubai),
    "PK" => ~w(Asia/Karachi),
    "IN" => ~w(Asia/Kolkata),
    "LK" => ~w(Asia/Colombo),
    "BD" => ~w(Asia/Dhaka),
    "TH" => ~w(Asia/Bangkok),
    "VN" => ~w(Asia/Ho_Chi_Minh),
    "MY" => ~w(Asia/Kuala_Lumpur),
    "SG" => ~w(Asia/Singapore),
    "ID" => ~w(Asia/Jakarta Asia/Makassar Asia/Jayapura),
    "PH" => ~w(Asia/Manila),
    "CN" => ~w(Asia/Shanghai),
    "KR" => ~w(Asia/Seoul),
    "JP" => ~w(Asia/Tokyo),
    "AU" => ~w(Australia/Sydney Australia/Brisbane Australia/Adelaide Australia/Darwin
               Australia/Perth),
    "NZ" => ~w(Pacific/Auckland),
    "MX" => ~w(America/Mexico_City America/Cancun America/Tijuana America/Hermosillo),
    "CO" => ~w(America/Bogota),
    "CL" => ~w(America/Santiago),
    "AR" => ~w(America/Argentina/Buenos_Aires),
    "BR" => ~w(America/Sao_Paulo America/Manaus America/Rio_Branco America/Noronha),
    "NG" => ~w(Africa/Lagos),
    "KE" => ~w(Africa/Nairobi),
    "ZA" => ~w(Africa/Johannesburg)
  }

  # The offsets off the whole hour, wherever the country is unknown.
  @off_the_hour ~w(Asia/Kolkata Asia/Kathmandu Asia/Kabul Asia/Tehran Asia/Yangon
                   Australia/Adelaide Australia/Darwin Australia/Eucla America/St_Johns
                   Pacific/Marquesas Pacific/Chatham)

  @doc "Every zone this module may answer with, for its test."
  def zones, do: Enum.uniq(List.flatten(Map.values(@by_country)) ++ @off_the_hour)

  @doc """
  The zone the client's local time names at `at`, or `nil`.

      iex> Core.Behaviour.Zone.from_local_time("3:42 PM", "Lahore, Pakistan", ~U[2026-11-14 10:41:30Z])
      "Asia/Karachi"
      iex> Core.Behaviour.Zone.from_local_time("5:42 AM", "United States", ~U[2026-11-14 10:41:30Z])
      "America/New_York"
      iex> Core.Behaviour.Zone.from_local_time("1:42 PM", nil, ~U[2026-11-14 10:41:30Z])
      "Etc/GMT-3"
      iex> Core.Behaviour.Zone.from_local_time("soon", "Pakistan", ~U[2026-11-14 10:41:30Z])
      nil
  """
  @spec from_local_time(String.t() | nil, String.t() | nil, DateTime.t()) :: String.t() | nil
  def from_local_time(nil, _location, _at), do: nil

  def from_local_time(text, location, %DateTime{} = at) do
    case offset_minutes(text, at) do
      nil -> nil
      offset -> in_country(offset, location, at) || fallback(offset, at)
    end
  end

  @doc """
  The client's offset from UTC in minutes, read from "3:42 PM" (or
  "15:42") against `at`, rounded to 15 minutes, between −12 h and +14 h.

      iex> Core.Behaviour.Zone.offset_minutes("3:42 PM", ~U[2026-11-14 10:41:30Z])
      300
      iex> Core.Behaviour.Zone.offset_minutes("4:12 pm local time", ~U[2026-11-14 10:41:30Z])
      330
  """
  @spec offset_minutes(String.t(), DateTime.t()) :: integer() | nil
  def offset_minutes(text, %DateTime{} = at) do
    with [_all, h, m | rest] <- Regex.run(~r/\b(\d{1,2}):(\d{2})\s*([AaPp]\.?[Mm]\.?)?/, text),
         {:ok, minutes} <- clock(String.to_integer(h), String.to_integer(m), List.first(rest)) do
      diff = minutes - (at.hour * 60 + at.minute)

      diff =
        cond do
          diff > 14 * 60 -> diff - 1440
          diff <= -12 * 60 -> diff + 1440
          true -> diff
        end

      round(diff / 15) * 15
    else
      _unreadable -> nil
    end
  end

  defp clock(h, m, nil) when h in 0..23 and m in 0..59, do: {:ok, h * 60 + m}

  defp clock(h, m, meridiem) when h in 1..12 and m in 0..59 do
    pm? = meridiem |> String.downcase() |> String.starts_with?("p")
    h = rem(h, 12) + if(pm?, do: 12, else: 0)
    {:ok, h * 60 + m}
  end

  defp clock(_h, _m, _meridiem), do: :error

  defp in_country(_offset, nil, _at), do: nil

  defp in_country(offset, location, at) do
    location
    |> Read.countries()
    |> Enum.flat_map(&Map.get(@by_country, &1, []))
    |> Enum.find(&(offset_at(&1, at) == offset))
  end

  defp fallback(0, _at), do: "Etc/UTC"

  defp fallback(offset, _at) when rem(offset, 60) == 0 and offset >= -720 and offset <= 840 do
    hours = div(offset, 60)
    # `Etc/GMT` names its sign the other way round: UTC+5 is Etc/GMT-5.
    if hours > 0, do: "Etc/GMT-#{hours}", else: "Etc/GMT+#{-hours}"
  end

  defp fallback(offset, at), do: Enum.find(@off_the_hour, &(offset_at(&1, at) == offset))

  defp offset_at(zone, at) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> div(local.utc_offset + local.std_offset, 60)
      {:error, _unknown} -> nil
    end
  end
end
