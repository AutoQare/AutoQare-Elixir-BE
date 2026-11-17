defmodule ApiTeam.CompanyControllerTest do
  @moduledoc "The console's company routes (AQ-03 §7): the picker, the card, its edit — §7.1's shapes."

  use ApiTeam.TeamCase, async: true

  @company ~w(behaviour created_by domain hq_country id industry inserted_at linkedin_url name notes_md
              open_jobs size_band time_zone time_zone_source website_url)

  setup do: board_cast_fixture()

  test "POST, GET, PATCH a company; the picker answers {id, name, domain}", c do
    conn =
      call(c.fiza, :post, "/v1/companies", %{name: "Bamboo Invest", domain: "bambooinvest.co.uk"})

    assert conn.status == 201
    company = body(conn)
    assert company |> Map.keys() |> Enum.sort() == @company

    assert %{"name" => "Bamboo Invest", "open_jobs" => [], "created_by" => %{"name" => "Fiza"}} =
             company

    assert body(call(c.muaz, :get, "/v1/companies?$where[q][$ILIKE]=bamboo")) ==
             [
               %{
                 "id" => company["id"],
                 "name" => "Bamboo Invest",
                 "domain" => "bambooinvest.co.uk"
               }
             ]

    refused = call(c.muaz, :get, "/v1/companies?$where[q][$EQUAL]=bamboo")
    assert refused.status == 422 and code(refused) == "invalid_filter"
    assert body(refused)["error"]["details"] == %{"q" => ["can't be filtered with $EQUAL"]}

    linkedin = "https://www.linkedin.com/company/bamboo-invest"

    assert %{"linkedin_url" => ^linkedin} =
             body(
               call(c.qasim, :patch, "/v1/companies/#{company["id"]}", %{linkedin_url: linkedin})
             )

    assert body(call(c.qasim, :get, "/v1/companies/#{company["id"]}"))["linkedin_url"] == linkedin
  end

  test "a second company of the same name is a field error", c do
    _first = call(c.fiza, :post, "/v1/companies", %{name: "Bamboo Invest"})
    conn = call(c.hira, :post, "/v1/companies", %{name: "bamboo invest"})

    assert conn.status == 422
    assert body(conn)["error"]["details"] == %{"name" => ["is already a company"]}
  end

  # AQ-10 §11.4: the zone by hand wins; null clears both; a name nobody knows is 422.
  test "PATCH time_zone: an IANA name is manual, null clears both, anything else is 422", c do
    company = body(call(c.fiza, :post, "/v1/companies", %{name: "Corvid Security"}))
    path = "/v1/companies/#{company["id"]}"

    assert %{"time_zone" => nil, "time_zone_source" => nil} = company

    assert %{"time_zone" => "Asia/Karachi", "time_zone_source" => "manual"} =
             body(call(c.qasim, :patch, path, %{time_zone: "Asia/Karachi"}))

    conn = call(c.qasim, :patch, path, %{time_zone: "Mars/Olympus"})
    assert conn.status == 422
    assert body(conn)["error"]["details"] == %{"time_zone" => ["is not a known IANA time zone"]}

    assert %{"time_zone" => nil, "time_zone_source" => nil} =
             body(call(c.qasim, :patch, path, %{time_zone: nil}))
  end
end
