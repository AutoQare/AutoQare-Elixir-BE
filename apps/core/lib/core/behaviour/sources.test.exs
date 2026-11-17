defmodule Core.Behaviour.SourcesTest do
  @moduledoc """
  AQ-10 §6.1, P10.0: each writer writes exactly one observation per
  fact — a new job, a repost, a moved *last viewed*, a reply by hand and
  captured — and a second capture of the same fact writes none; the hour
  counts move with them; a capture's Upwork client sets the company's
  zone, unless one was set by hand.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Behaviour
  alias Core.Behaviour.Sources
  alias Core.Conversations.Messages
  alias Core.Ingest.Conversation, as: Capture
  alias Core.Ingest.Extension
  alias Core.Jobs
  alias Data.Behaviour.{Observation, SubjectHour}

  doctest Sources

  @now ~U[2026-11-14 10:00:00.000000Z]
  @upwork "https://www.upwork.com/jobs/Go-developer_~01aa11bb22cc33dd44/"

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{fs: scope_for(c.fiza), ext: %{scope_for(c.fiza) | via: :extension}})
  end

  defp observations,
    do: Repo.all(from(o in Observation, order_by: [asc: o.inserted_at, asc: o.id]))

  defp hours(column, id), do: Repo.all(from(h in SubjectHour, where: field(h, ^column) == ^id))

  defp count(column, id),
    do: column |> hours(id) |> Enum.map(& &1.count) |> Enum.sum()

  defp company_named(c, name), do: Data.Companies.get_by_name(c.org.id, name)

  describe "jobs" do
    test "a new job writes job_posted for its company at noon of its posted day, once", c do
      params = %{
        url: "https://careers.corvid.example/jobs/1",
        title: "Senior Go Engineer",
        company: %{name: "Corvid Security"},
        posted_on: "2026-11-10"
      }

      assert {:ok, sheet} = Jobs.create(c.fs, in_team(params, c.fs), @now)
      corvid = company_named(c, "Corvid Security")

      assert [o] = observations()

      assert %{
               kind: :job_posted,
               source: :job,
               company_id: company_id,
               contact_id: nil,
               job_id: job_id,
               observed_at: @now,
               active_at: ~U[2026-11-10 07:00:00.000000Z]
             } = o

      assert company_id == corvid.id and job_id == sheet.id
      assert o.observer_user_id == c.fiza.id
      # Tuesday 07:00 UTC, the posted group.
      assert [%{kind_group: :posted, weekday: 2, hour: 7, count: 1}] =
               hours(:company_id, corvid.id)

      # The same fact again (the unique key) writes nothing, and counts nothing.
      assert {:ok, :exists} =
               Behaviour.observe(c.fs, %{
                 company_id: corvid.id,
                 kind: :job_posted,
                 source: :job,
                 observed_at: @now,
                 active_at: o.active_at,
                 job_id: sheet.id
               })

      assert length(observations()) == 1 and count(:company_id, corvid.id) == 1
    end

    test "a job reposted writes job_reposted; a job with no company writes nothing", c do
      {:ok, _} =
        Jobs.create(
          c.fs,
          in_team(
            %{
              url: "https://careers.corvid.example/jobs/2",
              title: "QA",
              company: %{name: "Corvid Security"},
              is_reposted: true
            },
            c.fs
          ),
          @now
        )

      {:ok, _} =
        Jobs.create(
          c.fs,
          in_team(%{url: "https://careers.x.example/jobs/3", title: "X"}, c.fs),
          @now
        )

      assert [%{kind: :job_reposted, active_at: @now}] = observations()
    end

    test "a capture first reading a pool job as reposted writes job_reposted; again, nothing",
         c do
      corvid = company_fixture(c.org, name: "Corvid Security")
      job = job_fixture(c.fs, team: c.backend, url: @upwork, company: corvid)
      params = %{"team_id" => c.backend.id, "url" => @upwork}
      fields = %{"title" => "Go developer", "posted_text" => "Reposted 2 days ago"}

      assert {:ok, %{state: "refreshed"}} =
               Extension.capture(c.ext, Map.put(params, "fields", fields), @now)

      assert [%{kind: :job_reposted, job_id: job_id, active_at: active_at}] = observations()
      assert job_id == job.id
      assert active_at == ~U[2026-11-12 07:00:00.000000Z]

      later = DateTime.add(@now, 86_400, :second)
      assert {:ok, _} = Extension.capture(c.ext, Map.put(params, "fields", fields), later)
      assert length(observations()) == 1
    end

    test "a moved last viewed writes last_active_reported for the company; the same read again, nothing",
         c do
      corvid = company_fixture(c.org, name: "Corvid Security")
      _job = job_fixture(c.fs, team: c.backend, url: @upwork, company: corvid)
      params = %{"team_id" => c.backend.id, "url" => @upwork}

      viewed = fn text ->
        Map.put(params, "fields", %{"upwork" => %{"last_viewed_text" => text}})
      end

      assert {:ok, _} =
               Extension.capture(c.ext, viewed.("Last viewed by client: 2 hours ago"), @now)

      assert [%{kind: :last_active_reported, source: :extension, active_at: at}] = observations()
      assert at == DateTime.add(@now, -7200, :second)

      # An hour later the page says "3 hours ago": the same moment, nothing new.
      an_hour = DateTime.add(@now, 3600, :second)
      assert {:ok, _} = Extension.capture(c.ext, viewed.("3 hours ago"), an_hour)
      assert length(observations()) == 1

      # The client looked again.
      assert {:ok, _} = Extension.capture(c.ext, viewed.("10 minutes ago"), an_hour)
      assert [_, %{kind: :last_active_reported}] = observations()
      assert count(:company_id, corvid.id) == 2
    end

    test "the Upwork client's local time sets the company's zone; a zone set by hand wins", c do
      corvid = company_fixture(c.org, name: "Corvid Security")
      _job = job_fixture(c.fs, team: c.backend, url: @upwork, company: corvid)

      fields = %{
        "upwork" => %{
          "client" => %{"local_time_text" => "3:00 PM", "location_text" => "Lahore, Pakistan"}
        }
      }

      body = %{"team_id" => c.backend.id, "url" => @upwork, "fields" => fields}
      assert {:ok, _} = Extension.capture(c.ext, body, @now)

      assert %{time_zone: "Asia/Karachi", time_zone_source: :upwork} =
               company_named(c, "Corvid Security")

      {:ok, _} = Core.Companies.update(c.fs, corvid.id, %{"time_zone" => "Europe/London"}, @now)
      assert {:ok, _} = Extension.capture(c.ext, body, @now)

      assert %{time_zone: "Europe/London", time_zone_source: :manual} =
               company_named(c, "Corvid Security")
    end
  end

  describe "replies" do
    setup c do
      lead = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
      mei = contact_fixture(c.fs, name: "Mei Chen", handles: [{:email, "mei@juniper.example"}])
      Map.merge(c, %{lead: lead, mei: mei})
    end

    defp log(scope, params), do: Messages.create(scope, params, @now)

    test "an inbound reply to one of ours, by hand: replied with its delay; to theirs, nothing",
         c do
      {:ok, conv} =
        log(c.fs, %{
          "lead_id" => c.lead.id,
          "platform" => "email",
          "direction" => "out",
          "from" => %{"kind" => "user"},
          "sent_at" => "2026-11-12T09:00:00Z",
          "body_md" => "Tanweer is a good fit."
        })

      [ours] = conv.messages

      {:ok, _} =
        log(c.fs, %{
          "conversation_id" => conv.id,
          "direction" => "in",
          "from" => %{"kind" => "contact", "contact_id" => c.mei.id},
          "sent_at" => "2026-11-12T12:00:00Z",
          "body_md" => "Thanks, let's talk.",
          "parent_message_id" => ours.id
        })

      assert [%{kind: :replied, source: :manual, contact_id: mei_id, reply_delay_s: 10_800} = o] =
               observations()

      assert mei_id == c.mei.id and o.active_at == ~U[2026-11-12 12:00:00.000000Z]

      assert [%{kind_group: :replied, weekday: 4, hour: 12, count: 1}] =
               hours(:contact_id, c.mei.id)

      # A second inbound answering hers is no reply to us.
      [_ours, theirs] = Repo.all(from(m in Data.Conversations.Message, order_by: m.sent_at))

      {:ok, _} =
        log(c.fs, %{
          "conversation_id" => conv.id,
          "direction" => "in",
          "from" => %{"kind" => "contact", "contact_id" => c.mei.id},
          "sent_at" => "2026-11-12T13:00:00Z",
          "body_md" => "Also: Tuesday?",
          "parent_message_id" => theirs.id
        })

      assert length(observations()) == 1
    end

    test "a captured chat has no tree: the message before it is its parent; a retry writes nothing",
         c do
      body = %{
        "request_id" => Ecto.UUID.generate(),
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id,
        "url" => "https://www.linkedin.com/messaging/thread/2-abc/",
        "fields" => %{
          "captured_at" => "2026-11-14T09:59:00Z",
          "page_kind" => "thread",
          "thread_id" => "2-abc",
          "other_profile_url" => "https://www.linkedin.com/in/mei-chen/",
          "other_name" => "Mei Chen",
          "messages" => [
            %{"side" => "us", "sent_text" => "Nov 12 9:00 AM", "text" => "Hi Mei"},
            %{"side" => "them", "sent_text" => "11:00 AM", "text" => "Hello!"},
            %{"side" => "them", "sent_text" => "11:05 AM", "text" => "When?"}
          ]
        }
      }

      assert {:ok, %{added: 3}} = Capture.capture(c.ext, body, @now)
      assert [%{kind: :replied, source: :extension, reply_delay_s: 7200}] = observations()

      assert {:ok, %{added: 0}} =
               Capture.capture(c.ext, %{body | "request_id" => Ecto.UUID.generate()}, @now)

      assert length(observations()) == 1
    end
  end
end
