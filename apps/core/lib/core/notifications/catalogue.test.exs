defmodule Core.Notifications.CatalogueTest do
  @moduledoc """
  The catalogue (AQ-10B §8, §11.4, QP10b-16) held equal to the code: every
  kind has a row, every row's kind exists, each row's channels are the
  seed's defaults for its audience (`staff` and `admin` the staff's,
  `customer` the customer's, `customer_no_login` email alone and only for
  the kinds such a customer is mailed), and `quiet` says whether the kind
  passes quiet hours. Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Core.Notifications.{Catalogue, CustomerMail}
  alias Data.Seeds.Notifications, as: Seed

  @channels ~w(inapp push extension email digest)
  @kinds Map.new(Seed.kinds(), fn {key, staff, customer} -> {key, {staff, customer || staff}} end)

  test "every row has the pinned shape" do
    for row <- Catalogue.rows() do
      assert Map.keys(row) |> Enum.sort() == ~w(audience channels event id kind quiet who)
      assert row["audience"] in ~w(staff customer customer_no_login admin), inspect(row)
      assert row["quiet"] in ~w(hold pass), inspect(row)
      assert row["id"] =~ ~r/^[A-Z]+\d+$/
      assert Map.keys(row["channels"]) |> Enum.sort() == Enum.sort(@channels)
      assert Enum.all?(Map.values(row["channels"]), &(&1 in [true, false, "offered"]))
    end
  end

  test "every kind has a row, and every row's kind exists" do
    named = for row <- Catalogue.rows(), row["kind"], uniq: true, do: row["kind"]

    assert Enum.sort(named) == Enum.sort(Seed.keys())
    assert Enum.sort(Map.keys(@kinds)) == Enum.sort(Seed.keys())
  end

  test "each row's channels are the seed's defaults for its audience" do
    for %{"kind" => kind} = row <- Catalogue.rows(), kind do
      {staff, customer} = Map.fetch!(@kinds, kind)

      expected =
        case row["audience"] do
          "customer_no_login" ->
            assert kind in CustomerMail.kinds(), "#{row["id"]} #{kind} isn't mailed"
            Map.new(@channels, &{&1, &1 == "email"})

          audience ->
            customer? = audience == "customer"
            channels = if customer?, do: customer, else: staff
            assert channels != [], "#{row["id"]} #{kind} isn't for #{audience}"
            offered = Seed.offered(kind, customer?)

            Map.new(@channels, fn c ->
              cond do
                c in channels -> {c, true}
                c in offered -> {c, "offered"}
                true -> {c, false}
              end
            end)
        end

      assert row["channels"] == expected, "#{row["id"]} #{kind} for #{row["audience"]}"
    end
  end

  test "quiet hours: `pass` exactly for the kinds that pass them" do
    for %{"kind" => kind} = row <- Catalogue.rows(), kind do
      passes? = kind in Seed.passing_quiet_hours()
      assert row["quiet"] == if(passes?, do: "pass", else: "hold"), "#{row["id"]} #{kind}"
    end
  end

  test "P1's mails and the account's direct ones are email alone" do
    for %{"kind" => nil} = row <- Catalogue.rows() do
      assert row["channels"] == Map.new(@channels, &{&1, &1 == "email"}), row["id"]
    end
  end
end
