defmodule ApiTeam.BehaviourRoutesTest do
  @moduledoc """
  The console's Behaviour routes (AQ-10 §11.4), through the router, with
  §11.4's exact shapes: the list, a subject's page and timeline, *Log an
  observation*, the watcher's own watches, *Forget* (403
  `forget_not_allowed` for staff), and the company and contact pages'
  `behaviour`.
  """

  use ApiTeam.TeamCase, async: true

  @behaviour_keys ~w(enough last_seen mine seen sentence time_zone time_zone_source watchers)
  @watch_keys ~w(channels cooldown_minutes expires_at id inserted_at is_expired last_fired_at
                 paused_at subject trigger)
  @observation_keys ~w(active_at conversation_id id job kind note observed_at observer
                       reply_delay_s source)

  setup do
    c = board_cast_fixture()
    corvid = company_fixture(c.org, name: "Corvid Security")
    _job = job_fixture(scope_for(c.qasim), team: c.backend, company: corvid, title: "Go")
    mei = contact_fixture(scope_for(c.fiza), name: "Mei Chen", company: corvid)
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
    {:ok, _} = Data.Contacts.link_lead(%{lead_id: lead.id, contact_id: mei.id, role: :recruiter})
    Map.merge(c, %{corvid: corvid, mei: mei})
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp an_hour_ago do
    DateTime.utc_now()
    |> DateTime.add(-3600, :second)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  test "log an observation, then the list, the page, the timeline and the company's card", c do
    conn =
      call(c.fiza, :post, "/v1/observations", %{
        company_id: c.corvid.id,
        kind: "seen_online",
        observed_at: an_hour_ago(),
        note: "Called, picked up."
      })

    assert conn.status == 201
    observation = body(conn)
    assert keys(observation) == @observation_keys

    assert %{"kind" => "seen_online", "source" => "manual", "observer" => %{"name" => "Fiza"}} =
             observation

    assert observation["active_at"] == observation["observed_at"]

    list = body(call(c.fiza, :get, "/v1/behaviour", %{team_id: c.backend.id}))
    assert keys(list) == ~w(items next_cursor)
    assert [row] = list["items"]
    assert keys(row) == ~w(last_seen leads_open sentence subject watchers_count watching)
    assert keys(row["subject"]) == ~w(company id kind name)

    assert row["subject"]["kind"] == "company" and
             row["sentence"] == "Not enough seen yet: 1 observation."

    assert keys(row["last_seen"]) == ~w(at words)

    named =
      body(
        call(
          c.fiza,
          :get,
          "/v1/behaviour?team_id=#{c.backend.id}&$where[kind][$IN][]=company&$where[q][$ILIKE]=corvid"
        )
      )

    assert [%{"subject" => %{"kind" => "company"}}] = named["items"]

    watched =
      body(call(c.fiza, :get, "/v1/behaviour?team_id=#{c.backend.id}&$where[watched][$EQUAL]=me"))

    assert watched["items"] == []

    refused =
      call(c.fiza, :get, "/v1/behaviour?team_id=#{c.backend.id}&$where[kind][$EQUAL]=lead")

    assert refused.status == 422 and code(refused) == "invalid_filter"

    assert body(refused)["error"]["details"] == %{
             "kind" => ["has a value this filter can't take"]
           }

    page = body(call(c.fiza, :get, "/v1/behaviour/company/#{c.corvid.id}"))
    assert keys(page) == ~w(behaviour cadence heat jobs observations reply_delay subject)
    assert keys(page["behaviour"]) == @behaviour_keys
    assert keys(page["heat"]) == ~w(ours theirs)
    assert keys(page["heat"]["ours"]) == ~w(cells zone) and page["heat"]["theirs"] == nil
    assert length(page["heat"]["ours"]["cells"]) == 7
    assert [%{"title" => "Go"}] = page["jobs"]
    assert %{"items" => [%{"id" => id}], "next_cursor" => nil} = page["observations"]
    assert id == observation["id"]

    assert %{"items" => [_one], "next_cursor" => nil} =
             body(call(c.fiza, :get, "/v1/behaviour/company/#{c.corvid.id}/observations"))

    card = body(call(c.fiza, :get, "/v1/companies/#{c.corvid.id}"))
    assert keys(card["behaviour"]) == @behaviour_keys
    assert Map.has_key?(card, "time_zone") and Map.has_key?(card, "time_zone_source")

    contact = body(call(c.fiza, :get, "/v1/contacts/#{c.mei.id}"))
    assert keys(contact["behaviour"]) == @behaviour_keys
    assert contact["behaviour"]["sentence"] == nil and contact["behaviour"]["seen"] == 0

    assert call(c.fiza, :get, "/v1/behaviour/lead/#{c.corvid.id}").status == 404

    conn =
      call(c.fiza, :post, "/v1/observations", %{
        contact_id: c.mei.id,
        kind: "visited",
        observed_at: an_hour_ago()
      })

    assert conn.status == 422 and code(conn) == "validation_failed"
  end

  test "watches: 201, 200 renewing the same, the list, pause, another person's 404, remove", c do
    sent = %{
      contact_id: c.mei.id,
      trigger: "replies",
      channels: ["push", "email"],
      cooldown_minutes: 30,
      expires_in: "week"
    }

    conn = call(c.fiza, :post, "/v1/watches", sent)
    assert conn.status == 201
    watch = body(conn)
    assert keys(watch) == @watch_keys
    assert keys(watch["subject"]) == ~w(id kind name)

    assert %{"trigger" => "replies", "channels" => ["push", "email"], "cooldown_minutes" => 30} =
             watch

    assert is_binary(watch["expires_at"])

    again = call(c.fiza, :post, "/v1/watches", %{sent | expires_in: nil, cooldown_minutes: 120})
    assert again.status == 200

    assert %{"id" => id, "expires_at" => nil, "is_expired" => false, "cooldown_minutes" => 120} =
             body(again)

    assert id == watch["id"]

    assert %{"items" => [%{"id" => ^id}]} = body(call(c.fiza, :get, "/v1/watches"))

    paused = body(call(c.fiza, :patch, "/v1/watches/#{id}", %{paused: true}))
    assert is_binary(paused["paused_at"])
    assert body(call(c.fiza, :patch, "/v1/watches/#{id}", %{paused: false}))["paused_at"] == nil

    assert call(c.hira, :patch, "/v1/watches/#{id}", %{paused: true}).status == 404
    assert call(c.hira, :delete, "/v1/watches/#{id}").status == 404

    page = body(call(c.hira, :get, "/v1/contacts/#{c.mei.id}"))
    assert [%{"id" => _, "name" => "Fiza"}] = page["behaviour"]["watchers"]
    assert page["behaviour"]["mine"] == []

    assert call(c.fiza, :delete, "/v1/watches/#{id}").status == 204
    assert call(c.fiza, :delete, "/v1/watches/#{id}").status == 404

    conn = call(c.fiza, :post, "/v1/watches", %{sent | trigger: "posts_job"})
    assert conn.status == 422 and body(conn)["error"]["details"]["trigger"]
  end

  test "Forget: 403 forget_not_allowed for staff; a team lead's 200 is the contact; its people",
       c do
    conn = call(c.fiza, :post, "/v1/contacts/#{c.mei.id}/forget", %{})
    assert conn.status == 403

    assert body(conn)["error"] == %{
             "code" => "forget_not_allowed",
             "message" => "Only a team lead can forget someone.",
             "details" => %{}
           }

    conn = call(c.hira, :post, "/v1/contacts/#{c.mei.id}/forget", %{})
    assert conn.status == 200
    contact = body(conn)
    assert contact["is_do_not_contact"] == true
    assert Map.has_key?(contact, "leads") and Map.has_key?(contact, "can")
    assert keys(contact["behaviour"]) == @behaviour_keys

    assert call(c.fiza, :post, "/v1/companies/#{c.corvid.id}/forget-people", %{}).status == 403

    assert body(call(c.bilal, :post, "/v1/companies/#{c.corvid.id}/forget-people", %{})) ==
             %{"forgotten" => 1}

    lonely = company_fixture(c.org, name: "Nobody's Co")
    assert call(c.hira, :post, "/v1/companies/#{lonely.id}/forget-people", %{}).status == 404
  end
end
