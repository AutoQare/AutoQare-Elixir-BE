defmodule Core.Dashboards.RatesTest do
  @moduledoc "Rates in basis points, `nil` on nothing to divide by, `few` under 5 (AQ-11 QP11-7)."

  use ExUnit.Case, async: true

  alias Core.Dashboards.Rates

  doctest Core.Dashboards.Rates

  test "nothing to divide by is no rate, and few" do
    assert Rates.of(0, 0) == %{count: 0, of: 0, rate_bp: nil, few: true}
    assert Rates.of(5, 5) == %{count: 5, of: 5, rate_bp: 10_000, few: false}
  end
end
