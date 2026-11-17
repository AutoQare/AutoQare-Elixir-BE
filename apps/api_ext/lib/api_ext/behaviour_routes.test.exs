defmodule ApiExt.BehaviourRoutesTest do
  @moduledoc """
  The panel's Behaviour routes (AQ-10 §11.4) on a device token: the open
  job's company and thread's contact with their summary (both `null`
  before there is one), presence (201, then 200 `replayed` for the same
  `request_id`; 422 for an unreadable text; 404 for a thread the team
  hasn't captured), and *Watch* with push and the extension and a 2-hour
  cool-down, removed by its owner alone.
  """

  use ApiExt.ExtCase, async: true

  @upwork "https://www.upwork.com/jobs/Go-developer_~01aa11bb22cc33dd44/"
  @behaviour_keys ~w(enough last_seen mine seen sentence time_zone time_zone_source watchers)

  setup do
    c = board_cast_fixture()
    {_device, tokens} = connected(c.fiza)
    corvid = company_fixture(c.org, name: "Corvid Security")
    _job = job_fixture(scope_for(c.fiza), team: c.backend, url: @upwork, company: corvid)

    capture = %{
      request_id: Ecto.UUID.generate(),
      team_id: c.backend.id,
      profile_id: c.golang.id,
      url: "https://www.upwork.com/ab/messages/rooms/room_77",
      fields: %{
        page_kind: "thread",
        thread_id: "room_77",
        other_name: "Dana Whitfield",
        messages: [%{side: "them", sent_text: "9:00 AM", text: "Hi"}]
      }
    }

    assert call(tokens.access_token, :post, "/v1/conversations/capture", capture).status == 200
    Map.merge(c, %{token: tokens.access_token, corvid: corvid})
  end

  defp presence(c, attrs) do
    Map.merge(
      %{
        team_id: c.backend.id,
        kind: "seen_online",
        thread: %{platform: "upwork", external_thread_id: "room_77"},
        request_id: Ecto.UUID.generate()
      },
      attrs
    )
  end

  test "GET /behaviour: a job's company, a thread's contact, nothing before there is one", c do
    job = body(call(c.token, :get, "/v1/behaviour", %{team_id: c.backend.id, url: @upwork}))
    assert keys(job) == ~w(behaviour subject)

    assert job["subject"] == %{
             "kind" => "company",
             "id" => c.corvid.id,
             "name" => "Corvid Security"
           }

    assert keys(job["behaviour"]) == @behaviour_keys

    thread =
      body(
        call(c.token, :get, "/v1/behaviour", %{
          team_id: c.backend.id,
          platform: "upwork",
          external_thread_id: "room_77"
        })
      )

    assert %{"subject" => %{"kind" => "contact", "name" => "Dana Whitfield"}} = thread

    none =
      call(c.token, :get, "/v1/behaviour", %{
        team_id: c.backend.id,
        url: "https://www.upwork.com/jobs/~01ff00ee11dd22cc33"
      })

    assert none.status == 200 and body(none) == %{"subject" => nil, "behaviour" => nil}

    assert body(
             call(c.token, :get, "/v1/behaviour", %{
               team_id: c.backend.id,
               platform: "linkedin",
               external_thread_id: "nope"
             })
           ) == %{"subject" => nil, "behaviour" => nil}

    assert call(c.token, :get, "/v1/behaviour", %{team_id: c.backend.id}).status == 422
  end

  test "POST /observations: 201, then 200 replayed; 422 unreadable; 404 no such thread", c do
    sent = presence(c, %{})
    first = call(c.token, :post, "/v1/observations", sent)
    assert first.status == 201
    assert %{"observation_id" => id} = body(first)
    assert keys(body(first)) == ~w(observation_id)

    again = call(c.token, :post, "/v1/observations", sent)
    assert again.status == 200
    assert body(again) == %{"observation_id" => id, "replayed" => true}

    active =
      call(
        c.token,
        :post,
        "/v1/observations",
        presence(c, %{kind: "last_active_reported", active_text: "Last seen 3 hours ago"})
      )

    assert active.status == 201

    unreadable =
      call(
        c.token,
        :post,
        "/v1/observations",
        presence(c, %{kind: "last_active_reported", active_text: "Away"})
      )

    assert unreadable.status == 422 and code(unreadable) == "validation_failed"

    gone = presence(c, %{thread: %{platform: "upwork", external_thread_id: "room_00"}})
    assert call(c.token, :post, "/v1/observations", gone).status == 404

    # The thread's contact now shows what was seen.
    thread =
      body(
        call(c.token, :get, "/v1/behaviour", %{
          team_id: c.backend.id,
          platform: "upwork",
          external_thread_id: "room_77"
        })
      )

    assert thread["behaviour"]["seen"] == 2
    assert thread["behaviour"]["last_seen"]["words"] == "Active now"
  end

  test "POST /watches: push and the extension, 2 h; 200 for the same; DELETE its owner's alone",
       c do
    sent = %{team_id: c.backend.id, company_id: c.corvid.id, trigger: "posts_job"}
    conn = call(c.token, :post, "/v1/watches", sent)
    assert conn.status == 201

    assert %{"id" => id, "channels" => ["push", "extension"], "cooldown_minutes" => 120} =
             body(conn)

    assert call(c.token, :post, "/v1/watches", sent).status == 200

    {_device, hira} = connected(c.hira)
    assert call(hira.access_token, :delete, "/v1/watches/#{id}").status == 404
    assert call(c.token, :delete, "/v1/watches/#{id}").status == 204
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()
end
