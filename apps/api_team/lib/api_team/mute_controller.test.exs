defmodule ApiTeam.MuteControllerTest do
  @moduledoc """
  AQ-10B §11.4's routes: *Watch* and *Mute* a lead, *Mute* a customer —
  204 with no body, the shapes' `watching`, `watchers_count` and `muted`.
  """

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
    Map.put(c, :lead, lead)
  end

  test "watch and mute a lead: 204; the sheet says so for me alone", c do
    assert call(c.hira, :post, "/v1/leads/#{c.lead.id}/watch").status == 204
    assert call(c.hira, :post, "/v1/leads/#{c.lead.id}/mute").status == 204

    assert %{"watching" => true, "watchers_count" => 1, "muted" => true} =
             body(call(c.hira, :get, "/v1/leads/#{c.lead.id}"))

    assert %{"watching" => false, "watchers_count" => 1, "muted" => false} =
             body(call(c.fiza, :get, "/v1/leads/#{c.lead.id}"))

    assert call(c.hira, :delete, "/v1/leads/#{c.lead.id}/watch").status == 204
    assert call(c.hira, :delete, "/v1/leads/#{c.lead.id}/mute").status == 204

    assert %{"watching" => false, "watchers_count" => 0, "muted" => false} =
             body(call(c.hira, :get, "/v1/leads/#{c.lead.id}"))

    assert call(c.hira, :post, "/v1/leads/#{Ecto.UUID.generate()}/watch").status == 404
  end

  test "mute a customer: 204; the customer shape's muted", c do
    assert call(c.fiza, :post, "/v1/customers/#{c.tanweer.id}/mute").status == 204
    assert %{"muted" => true} = body(call(c.fiza, :get, "/v1/customers/#{c.tanweer.id}"))
    assert %{"muted" => false} = body(call(c.qasim, :get, "/v1/customers/#{c.tanweer.id}"))

    assert Enum.find(body(call(c.fiza, :get, "/v1/customers")), &(&1["id"] == c.tanweer.id))[
             "muted"
           ]

    assert call(c.fiza, :delete, "/v1/customers/#{c.tanweer.id}/mute").status == 204
    assert %{"muted" => false} = body(call(c.fiza, :get, "/v1/customers/#{c.tanweer.id}"))
  end
end
