defmodule ApiTeam.TeamControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)
    %{org: org, backend: backend, frontend: frontend, admin: admin, lead: lead, member: member}
  end

  test "GET /teams, POST /teams, GET/PATCH /teams/:id, archive", %{
    admin: admin,
    lead: lead,
    member: member,
    backend: backend,
    frontend: frontend
  } do
    conn = call(admin, :get, "/v1/teams")
    assert conn.status == 200
    assert length(body(conn)) == 2
    assert [%{"id" => id}] = body(call(member, :get, "/v1/teams"))
    assert id == backend.id

    conn = call(admin, :post, "/v1/teams", %{name: "Data squad"})
    assert conn.status == 201

    assert %{
             "id" => _id,
             "name" => "Data squad",
             "slug" => "data-squad",
             "member_count" => 0,
             "archived_at" => nil
           } = body(conn)

    assert body(call(member, :get, "/v1/teams/#{backend.id}"))["member_count"] == 2

    assert call(admin, :post, "/v1/teams", %{name: ""}).status == 422
    assert code(call(member, :post, "/v1/teams", %{name: "Nope"})) == "forbidden"
    assert code(call(lead, :post, "/v1/teams", %{name: "Nope"})) == "forbidden"
    assert code(call(lead, :patch, "/v1/teams/#{backend.id}", %{name: "Nope"})) == "forbidden"
    assert code(call(lead, :post, "/v1/teams/#{backend.id}/archive")) == "forbidden"

    assert body(call(member, :get, "/v1/teams/#{backend.id}"))["name"] == "Backend squad"
    assert call(member, :get, "/v1/teams/#{frontend.id}").status == 404

    assert body(call(admin, :patch, "/v1/teams/#{backend.id}", %{name: "Backend"}))["name"] ==
             "Backend"

    assert body(call(admin, :post, "/v1/teams/#{backend.id}/archive"))["archived_at"]
  end

  test "team settings for a lead; a member is refused with words", %{
    lead: lead,
    member: member,
    backend: backend
  } do
    conn = call(lead, :get, "/v1/teams/#{backend.id}/settings")
    assert conn.status == 200

    assert body(conn) == %{
             "peer_tasks" => "view",
             "peer_leads" => "view",
             "peer_jobs" => "edit",
             "customer_sees_staff_names" => true,
             "customer_sees_conversations" => true,
             "customer_sees_job_suggestions" => false
           }

    conn =
      call(lead, :put, "/v1/teams/#{backend.id}/settings", %{
        customer_sees_staff_names: false,
        peer_tasks: "hidden"
      })

    assert %{
             "customer_sees_staff_names" => false,
             "peer_tasks" => "hidden",
             "peer_jobs" => "edit"
           } =
             body(conn)

    conn = call(lead, :put, "/v1/teams/#{backend.id}/settings", %{peer_jobs: "sometimes"})
    assert conn.status == 422 and Map.has_key?(body(conn)["error"]["details"], "peer_jobs")
    assert call(member, :get, "/v1/teams/#{backend.id}/settings").status == 403
  end

  test "members: list, change role (with the guards), remove", %{
    admin: admin,
    lead: lead,
    member: member,
    backend: backend
  } do
    conn = call(member, :get, "/v1/teams/#{backend.id}/members")
    assert conn.status == 200
    assert Enum.map(body(conn), & &1["role"]) |> Enum.sort() == ["lead", "member"]
    assert Enum.all?(body(conn), &Map.has_key?(&1, "display_name"))

    # §8.5: roles are the system admin's; a team lead is refused in its words.
    refused =
      call(lead, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{role: "lead"})

    assert refused.status == 403
    assert body(refused)["error"]["message"] == "Only the system admin can do that."

    no_manager =
      call(admin, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{role: "manager"})

    assert no_manager.status == 422

    conn =
      call(admin, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{role: "lead"})

    assert conn.status == 200
    assert body(conn)["role"] == "lead"

    assert call(admin, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{}).status ==
             422

    # A team lead removes staff, never another lead.
    assert call(lead, :delete, "/v1/teams/#{backend.id}/members/#{member.id}").status == 403

    # The team keeps a lead: both are leads now, so one may go.
    assert call(admin, :delete, "/v1/teams/#{backend.id}/members/#{member.id}").status == 204
    last = call(admin, :delete, "/v1/teams/#{backend.id}/members/#{lead.id}")
    assert last.status == 204

    # With one member left who is not a lead, removing the only lead is refused.
    org = admin |> scope_for() |> Map.fetch!(:organisation)
    team = team_fixture(org)
    only_lead = member_fixture(team, :lead)
    _member = member_fixture(team, :member)
    refused = call(admin, :delete, "/v1/teams/#{team.id}/members/#{only_lead.id}")
    assert refused.status == 403
    assert body(refused)["error"]["message"] =~ "needs a lead"
  end

  # AQ-11 §7.4: a member's daily target.
  @member ~w(daily_target display_name email joined_at left_at role target_today team_id user_id)

  test "a member's daily target: listed with today's, set by the team lead, null for the profiles' sum",
       %{lead: lead, member: member, backend: backend} do
    [row | _rest] = body(call(member, :get, "/v1/teams/#{backend.id}/members"))
    assert row |> Map.keys() |> Enum.sort() == @member

    set = call(lead, :patch, "/v1/teams/#{backend.id}/members/#{member.id}", %{daily_target: 40})
    assert set.status == 200
    assert %{"daily_target" => 40, "user_id" => user_id} = body(set)
    assert body(set) |> Map.keys() |> Enum.sort() == @member
    assert user_id == member.id

    cleared =
      call(lead, :patch, "/v1/teams/#{backend.id}/members/#{member.id}", %{daily_target: nil})

    assert %{"daily_target" => nil} = body(cleared)

    assert call(lead, :patch, "/v1/teams/#{backend.id}/members/#{member.id}", %{daily_target: -1}).status ==
             422

    assert code(
             call(member, :patch, "/v1/teams/#{backend.id}/members/#{lead.id}", %{daily_target: 9})
           ) ==
             "forbidden"
  end
end
