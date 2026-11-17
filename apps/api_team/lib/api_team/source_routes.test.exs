defmodule ApiTeam.SourceRoutesTest do
  @moduledoc """
  AQ-12 §11.4 over HTTP, the console's half of alerts and Fiverr: `POST
  /jobs` for Fiverr with no `url` (the sheet's `source_url` null), its
  field errors; `GET /jobs?$where[origin_kind]` (the console's
  `from=alert`) with each row's `origin_kind` and `alert` chip, and the
  422 on an operator it doesn't take; `POST
  /conversations/:id/create-lead` on a Fiverr conversation with
  `origin_kind` and no link.
  """

  use ApiTeam.TeamCase, async: true

  alias Core.Inbound
  alias Data.Scope

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    channel = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    Map.put(c, :channel, Data.Channels.reload(channel))
  end

  defp deliver(c, name) do
    raw = File.read!(Path.expand("../../../core/priv/eml/" <> name, __DIR__))
    to = Inbound.address(c.channel.inbound_token)
    {:ok, answer} = Inbound.dev(Scope.system(), %{"to" => to, "eml" => raw}, @now)
    answer
  end

  test "POST /jobs for Fiverr: no url, origin_kind, the sheet's source_url null", c do
    conn =
      call(c.fiza, :post, "/v1/jobs", %{
        team_id: c.backend.id,
        source: "fiverr",
        origin_kind: "order",
        title: "Go webhook service"
      })

    assert conn.status == 201

    job = body(conn)
    assert %{"source" => "fiverr", "source_url" => nil, "origin_kind" => "order"} = job
    assert job["canonical_key"] == "fiverr:job:" <> job["id"] and job["alert"] == nil

    missing =
      call(c.fiza, :post, "/v1/jobs", %{team_id: c.backend.id, source: "fiverr", title: "Gig"})

    assert missing.status == 422 and body(missing)["error"]["details"]["origin_kind"]
  end

  test "GET /jobs with $where[origin_kind]: the alert's jobs, each with its chip", c do
    %{alert_jobs: 3} = deliver(c, "linkedin-alert.eml")
    _manual = job_fixture(scope_for(c.fiza), team: c.backend, title: "Typed by hand")

    conn =
      call(c.hira, :get, "/v1/jobs", %{
        "team_id" => c.backend.id,
        "$where" => %{"origin_kind" => %{"$EQUAL" => "alert"}}
      })

    assert conn.status == 200
    rows = body(conn)["items"]
    assert length(rows) == 3

    for row <- rows do
      assert row["origin_kind"] == "alert"

      assert row["alert"] == %{
               "profile" => %{
                 "id" => c.golang.id,
                 "title" => "Golang backend",
                 "customer_name" => "Tanweer"
               }
             }
    end

    refused =
      call(c.hira, :get, "/v1/jobs", %{
        "team_id" => c.backend.id,
        "$where" => %{"origin_kind" => %{"$GT" => "alert"}}
      })

    assert refused.status == 422 and code(refused) == "invalid_filter"
  end

  test "POST /conversations/:id/create-lead on a Fiverr conversation: origin_kind, no link", c do
    %{conversation_id: id} = deliver(c, "fiverr-brief.eml")
    path = "/v1/conversations/#{id}/create-lead"
    job = %{title: "Go microservice for payment webhooks"}

    refused = call(c.fiza, :post, path, %{profile_id: c.golang.id, job: job})
    assert refused.status == 422 and body(refused)["error"]["details"]["origin_kind"]

    conn = call(c.fiza, :post, path, %{profile_id: c.golang.id, job: job, origin_kind: "brief"})
    assert conn.status in [200, 201]
    lead_id = body(conn)["lead"]["id"]
    assert Data.Leads.get(c.org.id, lead_id).job.canonical_key == "fiverr:conversation:" <> id
  end
end
