defmodule Core.Dashboards.Windows do
  @moduledoc """
  The dashboards' calendar windows (AQ-11 §4, QP11-3), **pure**: `now` and
  the organisation's zone in, days and instants out. *Today* is the local
  day, *this week* runs from Monday, *this month* from the 1st; a cohort is
  this month, last month or the last 90 days. **Both ends are built from
  dates** (`Date` + `DateTime.new/4`), never by adding seconds, so a day
  that a clock change makes 23 or 25 hours long is still one day.

  A window is `{from, to}` in UTC, `to` exclusive: the first instant of
  its first day and the first instant of the day after its last. A period
  covers its whole calendar span, so a meeting later today is in *today*.
  """

  @periods %{"today" => :today, "week" => :week, "month" => :month}
  @cohorts %{"this_month" => :this_month, "last_month" => :last_month, "last_90" => :last_90}
  @period_labels %{today: "Today", week: "This week", month: "This month"}
  @cohort_labels %{
    this_month: "This month",
    last_month: "Last month",
    last_90: "The last 90 days"
  }

  @type window :: {DateTime.t(), DateTime.t()}

  @doc """
  A period's key from a query string: `today` (the default), `week`,
  `month`; anything else is a field error.

      iex> Core.Dashboards.Windows.period_key(nil)
      {:ok, :today}
      iex> Core.Dashboards.Windows.period_key("week")
      {:ok, :week}
  """
  @spec period_key(term()) :: {:ok, atom()} | {:error, term()}
  def period_key(value), do: key(value, @periods, :today, "period", "is today, week or month")

  @doc """
  A cohort's key: `this_month` (the default), `last_month`, `last_90`.

      iex> Core.Dashboards.Windows.cohort_key("last_90")
      {:ok, :last_90}
  """
  @spec cohort_key(term()) :: {:ok, atom()} | {:error, term()}
  def cohort_key(value),
    do: key(value, @cohorts, :this_month, "cohort", "is this_month, last_month or last_90")

  defp key(value, _known, default, _field, _words) when value in [nil, ""], do: {:ok, default}

  defp key(value, known, _default, field, words) do
    case Map.fetch(known, to_string(value)) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:invalid, %{field => [words]}}}
    end
  end

  @doc """
  A period at `now` in `zone`: `%{key, first, last, from, to, label}`
  (`first` and `last` the days, inclusive).

      iex> p = Core.Dashboards.Windows.period(:week, ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      iex> {p.first, p.last, p.from, p.to}
      {~D[2026-11-09], ~D[2026-11-15], ~U[2026-11-08 19:00:00.000000Z], ~U[2026-11-15 19:00:00.000000Z]}
  """
  @spec period(atom(), DateTime.t(), String.t()) :: map()
  def period(key, %DateTime{} = now, zone) do
    today = today(now, zone)
    {first, last} = span(key, today)
    build(key, first, last, zone, @period_labels[key])
  end

  @doc """
  A cohort at `now` in `zone`, the same shape: this month (the 1st to its
  last day), last month, or the 90 days ending today.

      iex> c = Core.Dashboards.Windows.cohort(:last_month, ~U[2026-11-14 10:00:00Z], "Asia/Karachi")
      iex> {c.first, c.last}
      {~D[2026-10-01], ~D[2026-10-31]}
  """
  @spec cohort(atom(), DateTime.t(), String.t()) :: map()
  def cohort(key, %DateTime{} = now, zone) do
    today = today(now, zone)

    {first, last} =
      case key do
        :this_month ->
          span(:month, today)

        :last_month ->
          today |> Date.beginning_of_month() |> Date.add(-1) |> then(&span(:month, &1))

        :last_90 ->
          {Date.add(today, -89), today}
      end

    build(key, first, last, zone, @cohort_labels[key])
  end

  defp span(:today, today), do: {today, today}

  defp span(:week, today),
    do: {Date.beginning_of_week(today, :monday), Date.end_of_week(today, :monday)}

  defp span(:month, today), do: {Date.beginning_of_month(today), Date.end_of_month(today)}

  defp build(key, first, last, zone, label) do
    {from, to} = window(first, last, zone)
    %{key: key, first: first, last: last, from: from, to: to, label: label}
  end

  @doc "The window from the start of `first` to the start of the day after `last`, in `zone`."
  @spec window(Date.t(), Date.t(), String.t()) :: window()
  defdelegate window(first, last, zone), to: Utils.Days

  @doc "One day's window in `zone`."
  @spec day(Date.t(), String.t()) :: window()
  def day(%Date{} = on, zone), do: window(on, on, zone)

  @doc """
  The days of the week holding `today`, Monday to `today`, that are working
  days (`working_days`, ISO weekdays).

      iex> Core.Dashboards.Windows.week_so_far(~D[2026-11-12], [1, 2, 3, 4, 5])
      [~D[2026-11-09], ~D[2026-11-10], ~D[2026-11-11], ~D[2026-11-12]]
  """
  @spec week_so_far(Date.t(), [1..7]) :: [Date.t()]
  def week_so_far(%Date{} = today, working_days) do
    today
    |> Date.beginning_of_week(:monday)
    |> Date.range(today)
    |> Enum.filter(&working?(&1, working_days))
  end

  @doc """
  Whether `on` carries a target.

      iex> Core.Dashboards.Windows.working?(~D[2026-11-14], [1, 2, 3, 4, 5])
      false
  """
  @spec working?(Date.t(), [1..7]) :: boolean()
  def working?(%Date{} = on, working_days), do: Date.day_of_week(on) in working_days

  @doc "The calendar day of `now` in `zone` (UTC's for a zone it can't read): `Utils.Days`'."
  @spec today(DateTime.t(), String.t()) :: Date.t()
  defdelegate today(now, zone), to: Utils.Days

  @doc """
  The first instant of `on` in `zone`, in UTC (`Utils.Days`', the copy the
  lists' date filters read too). A midnight that a clock change skips
  starts when the day does; one it repeats, at the first.

      iex> Core.Dashboards.Windows.start_of(~D[2026-03-29], "Europe/London")
      ~U[2026-03-29 00:00:00.000000Z]
      iex> Core.Dashboards.Windows.start_of(~D[2026-03-30], "Europe/London")
      ~U[2026-03-29 23:00:00.000000Z]
  """
  @spec start_of(Date.t(), String.t()) :: DateTime.t()
  defdelegate start_of(on, zone), to: Utils.Days

  @doc "The days and window as the API answers them: `%{key, from, to, label}` (days)."
  @spec json(map()) :: map()
  def json(%{key: key, first: first, last: last, label: label}),
    do: %{key: key, from: first, to: last, label: label}
end
