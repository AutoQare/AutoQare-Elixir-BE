defmodule Core.Dashboards.Rates do
  @moduledoc """
  Rates (AQ-11 §7.4, QP11-7), **pure**: integer **basis points**, `nil`
  when there is nothing to divide by (shown "—"), always beside their
  counts, and `few: true` under 5 (the screen says "few" rather than a
  misleading "100%" of one).
  """

  @few 5

  @doc """
  `part` of `whole` in basis points, rounded down; `nil` on a zero whole.

      iex> Core.Dashboards.Rates.rate_bp(1, 3)
      3333
      iex> Core.Dashboards.Rates.rate_bp(0, 0)
      nil
  """
  @spec rate_bp(non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def rate_bp(_part, 0), do: nil
  def rate_bp(part, whole), do: div(part * 10_000, whole)

  @doc """
  Whether a rate rests on too few to read: under #{@few}.

      iex> Core.Dashboards.Rates.few?(4)
      true
  """
  @spec few?(non_neg_integer()) :: boolean()
  def few?(whole), do: whole < @few

  @doc """
  A rate with its counts: `%{count, of, rate_bp, few}`.

      iex> Core.Dashboards.Rates.of(2, 8)
      %{count: 2, of: 8, rate_bp: 2500, few: false}
  """
  @spec of(non_neg_integer(), non_neg_integer()) :: map()
  def of(count, whole),
    do: %{count: count, of: whole, rate_bp: rate_bp(count, whole), few: few?(whole)}
end
