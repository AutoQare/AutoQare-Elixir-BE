defmodule ApiTeam.OrgControllerTest do
  use ApiTeam.TeamCase, async: true

  @admin_words "Only the system admin can do that."

  setup do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org)
    admin = admin_fixture(org)
    lead = member_fixture(team, :lead)
    %{org: org, team: team, admin: admin, lead: lead, member: member_fixture(team, :member)}
  end

  test "GET /org and PUT /org/settings: Settings › System, the system admin's alone", %{
    org: org,
    admin: admin,
    lead: lead,
    member: member
  } do
    conn = call(admin, :get, "/v1/org")
    assert conn.status == 200

    assert %{
             "id" => id,
             "name" => "Regbits BD",
             "settings" => %{"follow_up_gap_days" => 3}
           } = body(conn)

    assert id == org.id

    conn = call(admin, :put, "/v1/org/settings", %{follow_up_gap_days: 4, currency_code: "PKR"})
    assert conn.status == 200
    assert body(conn)["settings"]["follow_up_gap_days"] == 4
    assert body(conn)["currency_code"] == "PKR"

    assert call(admin, :put, "/v1/org/settings", %{warning_days: 0}).status == 422

    for who <- [lead, member] do
      refused = call(who, :get, "/v1/org")
      assert refused.status == 403
      assert body(refused)["error"]["message"] == @admin_words
      assert code(call(who, :put, "/v1/org/settings", %{warning_days: 2})) == "forbidden"
    end
  end

  test "the admins routes are gone (QP4a-21)", %{admin: admin, lead: lead} do
    assert call(admin, :get, "/v1/org/admins").status == 404
    assert call(admin, :post, "/v1/org/admins", %{user_id: lead.id}).status == 404
    assert call(admin, :delete, "/v1/org/admins/#{lead.id}").status == 404
  end

  test "GET /org/audit pages the log for the system admin, not a team lead or a member", %{
    admin: admin,
    lead: lead,
    member: member,
    team: team
  } do
    call(admin, :patch, "/v1/teams/#{team.id}", %{name: "Renamed"})
    conn = call(admin, :get, "/v1/org/audit")
    assert conn.status == 200
    assert %{"items" => [event | _rest], "next_cursor" => nil} = body(conn)

    assert %{
             "action" => "updated",
             "subject_kind" => "teams",
             "actor_name" => "Test Person",
             "via" => "web",
             "before" => %{"name" => _old}
           } = event

    conn =
      call(
        admin,
        :get,
        "/v1/org/audit?$where[subject_kind][$EQUAL]=teams&$where[subject_id][$EQUAL]=#{team.id}"
      )

    assert length(body(conn)["items"]) == 1

    conn =
      call(
        admin,
        :get,
        "/v1/org/audit?$where[occurred_at][$CAST_TO_DATE_GTE]=2000-01-01&$where[occurred_at][$CAST_TO_DATE_LTE]=2999-12-31"
      )

    assert body(conn)["items"] != []

    conn = call(admin, :get, "/v1/org/audit?$where[occurred_at][$CAST_TO_DATE_LTE]=2000-01-01")
    assert body(conn)["items"] == []

    refused = call(admin, :get, "/v1/org/audit?$where[occurred_at][$CAST_TO_DATE_GTE]=yesterday")
    assert refused.status == 422
    assert body(refused)["error"]["code"] == "invalid_filter"
    assert Map.keys(body(refused)["error"]["details"]) == ["occurred_at"]

    assert body(call(admin, :get, "/v1/org/audit?$where[via][$EQUAL]=web"))["error"]["code"] ==
             "invalid_filter"

    assert call(lead, :get, "/v1/org/audit").status == 403
    assert call(member, :get, "/v1/org/audit").status == 403
    assert call(admin, :get, "/v1/org/audit?cursor=garbage").status == 422
  end

  test "the emails' footer: help_email and postal_address set, read at the top and in settings, cleared with null",
       %{admin: admin} do
    set =
      call(admin, :put, "/v1/org/settings", %{
        help_email: " help@regbits.example ",
        postal_address: "12 Mall Road, Lahore"
      })

    assert set.status == 200

    assert %{
             "help_email" => "help@regbits.example",
             "postal_address" => "12 Mall Road, Lahore",
             "settings" => %{"help_email" => "help@regbits.example"}
           } = body(set)

    # AQ-10B §11.4's names for the same routes.
    assert %{"help_email" => "help@regbits.example"} = body(call(admin, :get, "/v1/organisation"))

    cleared = call(admin, :patch, "/v1/organisation", %{help_email: nil, postal_address: nil})
    assert cleared.status == 200
    assert %{"help_email" => nil, "postal_address" => nil} = body(cleared)

    bad = call(admin, :put, "/v1/org/settings", %{help_email: "not an address"})
    assert bad.status == 422
    assert body(bad)["error"]["details"]["help_email"]
  end

  test "working days (AQ-11 §7.4): Monday to Friday by default, set as ISO weekdays, checked",
       %{admin: admin, lead: lead} do
    assert %{
             "working_days" => [1, 2, 3, 4, 5],
             "settings" => %{"working_days" => [1, 2, 3, 4, 5]}
           } =
             body(call(admin, :get, "/v1/org"))

    set = call(admin, :put, "/v1/org/settings", %{working_days: [6, 1, 2, 3, 4, 5]})
    assert set.status == 200
    assert %{"working_days" => [1, 2, 3, 4, 5, 6]} = body(set)

    for bad <- [[0], [8], [1, 1]] do
      refused = call(admin, :put, "/v1/org/settings", %{working_days: bad})
      assert refused.status == 422
      assert body(refused)["error"]["details"]["working_days"]
    end

    assert code(call(lead, :put, "/v1/org/settings", %{working_days: [1]})) == "forbidden"
  end
end
