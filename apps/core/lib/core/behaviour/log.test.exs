defmodule Core.Behaviour.LogTest do
  @moduledoc """
  AQ-10 §6.1, §11.4: *Log an observation* (any kind, a time, a note of
  at most 500) and the extension's presence on a thread's contact,
  idempotent by `request_id`, with their refusals.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Behaviour.Log
  alias Core.Ingest.Conversation, as: Capture
  alias Data.Behaviour.Observation

  doctest Log

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{fs: scope_for(c.fiza), ext: %{scope_for(c.fiza) | via: :extension}})
  end

  defp observations,
    do: Repo.all(from(o in Observation, order_by: [asc: o.inserted_at, asc: o.id]))

  describe "by hand" do
    setup c do
      job =
        job_fixture(c.fs, team: c.backend, company: company_fixture(c.org, name: "Bamboo Invest"))

      %{bamboo: Data.Companies.get(c.org.id, job.company_id)}
    end

    test "any kind, a time, a note: 201's observation, source manual", c do
      assert {:ok, o} =
               Log.manual(
                 c.fs,
                 %{
                   "company_id" => c.bamboo.id,
                   "kind" => "seen_online",
                   "observed_at" => "2026-11-14T09:00:00Z",
                   "note" => "  Called at 14:00, picked up.  "
                 },
                 @now
               )

      assert %{
               kind: :seen_online,
               source: :manual,
               observed_at: ~U[2026-11-14 09:00:00.000000Z],
               active_at: ~U[2026-11-14 09:00:00.000000Z],
               note: "Called at 14:00, picked up.",
               observer: %{name: "Fiza"},
               job: nil,
               reply_delay_s: nil
             } = o

      # A reply logged by hand needs no delay.
      assert {:ok, %{kind: :replied, reply_delay_s: nil}} =
               Log.manual(
                 c.fs,
                 %{
                   "company_id" => c.bamboo.id,
                   "kind" => "replied",
                   "observed_at" => "2026-11-14T09:30:00Z"
                 },
                 @now
               )
    end

    test "422: the future, a note over 500, an unknown kind, both subjects or none; 404 unseen",
         c do
      base = %{
        "company_id" => c.bamboo.id,
        "kind" => "seen_online",
        "observed_at" => "2026-11-14T09:00:00Z"
      }

      log = &Log.manual(c.fs, Map.merge(base, &1), @now)

      assert {:error, {:invalid, %{"observed_at" => ["can't be in the future"]}}} =
               log.(%{"observed_at" => "2026-11-14T11:00:00Z"})

      # A clock a minute ahead is now.
      assert {:ok, %{observed_at: @now}} = log.(%{"observed_at" => "2026-11-14T10:01:00Z"})

      assert {:error, {:invalid, %{"note" => ["is at most 500 characters"]}}} =
               log.(%{"note" => String.duplicate("a", 501)})

      assert {:error, {:invalid, %{"kind" => [_]}}} = log.(%{"kind" => "visited"})
      assert {:error, {:missing, [:observed_at]}} = log.(%{"observed_at" => nil})
      assert {:error, {:invalid, %{"company_id" => [_]}}} = log.(%{"contact_id" => c.bamboo.id})
      assert {:error, {:invalid, %{"company_id" => [_]}}} = log.(%{"company_id" => nil})

      lonely = company_fixture(c.org, name: "Nobody's Co")
      assert {:error, :not_found} = log.(%{"company_id" => lonely.id})
      assert {:error, :not_found} = Log.manual(customer_scope_for(c.tanweer), base, @now)
    end
  end

  describe "the extension's presence" do
    setup c do
      body = %{
        "request_id" => Ecto.UUID.generate(),
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id,
        "url" => "https://www.upwork.com/ab/messages/rooms/room_77",
        "fields" => %{
          "page_kind" => "thread",
          "thread_id" => "room_77",
          "other_profile_url" => "https://www.upwork.com/freelancers/~0dana",
          "other_name" => "Dana Whitfield",
          "messages" => [%{"side" => "them", "sent_text" => "9:00 AM", "text" => "Hi"}]
        }
      }

      {:ok, _} = Capture.capture(c.ext, body, @now)
      %{thread: %{"platform" => "upwork", "external_thread_id" => "room_77"}}
    end

    defp presence(c, attrs) do
      Map.merge(
        %{
          "team_id" => c.backend.id,
          "kind" => "seen_online",
          "thread" => c.thread,
          "request_id" => Ecto.UUID.generate()
        },
        attrs
      )
    end

    test "seen_online on the thread's contact; the same request_id replays", c do
      body = presence(c, %{})
      assert {:ok, {:created, id}} = Log.extension(c.ext, body, @now)
      assert {:ok, {:replayed, ^id}} = Log.extension(c.ext, body, @now)

      dana = Repo.get_by!(Data.Contacts.Contact, name: "Dana Whitfield")

      assert [
               %{
                 id: ^id,
                 kind: :seen_online,
                 source: :extension,
                 active_at: @now,
                 contact_id: cid
               }
             ] =
               observations()

      assert cid == dana.id
    end

    test "last_active_reported reads the Active text; unreadable is 422; no such thread is 404",
         c do
      assert {:ok, {:created, _id}} =
               Log.extension(
                 c.ext,
                 presence(c, %{"kind" => "last_active_reported", "active_text" => "Active 2h ago"}),
                 @now
               )

      assert [%{kind: :last_active_reported, active_at: at}] = observations()
      assert at == DateTime.add(@now, -7200, :second)

      assert {:error, {:invalid, %{"active_text" => _}}} =
               Log.extension(
                 c.ext,
                 presence(c, %{"kind" => "last_active_reported", "active_text" => "Busy"}),
                 @now
               )

      assert {:error, {:missing, [:active_text]}} =
               Log.extension(c.ext, presence(c, %{"kind" => "last_active_reported"}), @now)

      assert {:error, {:invalid, %{"kind" => _}}} =
               Log.extension(c.ext, presence(c, %{"kind" => "replied"}), @now)

      gone = %{"platform" => "upwork", "external_thread_id" => "room_00"}
      assert {:error, :not_found} = Log.extension(c.ext, presence(c, %{"thread" => gone}), @now)

      assert {:error, {:missing, [:request_id]}} =
               Log.extension(c.ext, presence(c, %{"request_id" => nil}), @now)
    end
  end
end
