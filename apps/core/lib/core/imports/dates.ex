defmodule Core.Imports.Dates do
  @moduledoc """
  A sheet's date as written, read in the import's order (AQ-12 QP12-8),
  pure: `today` is the caller's.

  | Written | Read |
  |---|---|
  | `2024-10-09` (ISO, a time after it ignored) | 9 Oct 2024 |
  | `10/9/2026`, `10-09-26`, `10.9.2026` | day/month: 10 Sep 2026; month/day: 9 Oct 2026 (a two-digit year is 20xx) |
  | `9 Oct 2024`, `Oct 9, 2024`, `09-Oct-24` | 9 Oct 2024, whatever the order |
  | `45574` (a spreadsheet's day number) | the day it counts to from 30 Dec 1899 |

  An impossible day (`31/02/2024`) and a day after `today` are refused with
  the words the preview shows.
  """

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc """
  The day `text` names: `{:ok, date}` or `{:error, words}`.

      iex> Core.Imports.Dates.read("10/9/2026", :day_month, ~D[2026-11-15])
      {:ok, ~D[2026-09-10]}
      iex> Core.Imports.Dates.read("10/9/2026", :month_day, ~D[2026-11-15])
      {:ok, ~D[2026-10-09]}
      iex> Core.Imports.Dates.read("31/02/2024", :day_month, ~D[2026-11-15])
      {:error, "31/02/2024 isn't a date."}
  """
  @spec read(String.t() | nil, atom() | String.t(), Date.t()) ::
          {:ok, Date.t()} | {:error, String.t()}
  def read(text, order, %Date{} = today) do
    case Utils.presence(text || "") do
      nil -> {:error, "No date."}
      written -> written |> parse(to_string(order)) |> held(written, today)
    end
  end

  defp held(nil, written, _today), do: {:error, "#{written} isn't a date."}

  defp held({:ok, date}, written, today) do
    if Date.after?(date, today), do: {:error, "#{written} is in the future."}, else: {:ok, date}
  end

  defp parse(text, order) do
    cond do
      match = Regex.run(~r/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ].*)?$/, text) ->
        [_all, y, m, d] = match
        new(y, m, d)

      match = Regex.run(~r/^(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{2}|\d{4})$/, text) ->
        [_all, a, b, y] = match
        if order == "month_day", do: new(y, a, b), else: new(y, b, a)

      match = Regex.run(~r/^(\d{1,2})[\s\/.-]+([A-Za-z]{3,})[\s\/.,-]+(\d{2}|\d{4})$/, text) ->
        [_all, d, month, y] = match
        named(y, month, d)

      match = Regex.run(~r/^([A-Za-z]{3,})[\s.-]+(\d{1,2}),?[\s\/.-]+(\d{2}|\d{4})$/, text) ->
        [_all, month, d, y] = match
        named(y, month, d)

      text =~ ~r/^\d{5}$/ ->
        serial(String.to_integer(text))

      true ->
        nil
    end
  end

  defp named(y, month, d) do
    case Enum.find_index(@months, &(&1 == month |> String.downcase() |> String.slice(0, 3))) do
      nil -> nil
      i -> new(y, Integer.to_string(i + 1), d)
    end
  end

  defp new(y, m, d) do
    year = String.to_integer(y)
    year = if year < 100, do: 2000 + year, else: year

    case Date.new(year, String.to_integer(m), String.to_integer(d)) do
      {:ok, date} -> {:ok, date}
      {:error, _invalid} -> nil
    end
  end

  # A spreadsheet's day number, in the years a sheet of applications holds.
  defp serial(n) when n in 20_000..80_000, do: {:ok, Date.add(~D[1899-12-30], n)}
  defp serial(_n), do: nil
end
