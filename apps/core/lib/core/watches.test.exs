defmodule Core.WatchesTest do
  @moduledoc """
  AQ-10 P10.2: a watch is its owner's own; each trigger fires once per
  cool-down, to the watcher alone, on the watch's channels; a paused or
  expired watch fires nothing; only *comes online* passes quiet hours;
  the triggers a subject takes; the extension's defaults.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Behaviour
  alias Core.Behaviour.Log
  alias Core.Behaviour.Privacy
  alias Core.Organisation.Teams
  alias Core.Watches
  alias Data.Notifications.{Deliveries, Notification}

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    corvid = company_fixture(c.org, name: "Corvid Security")
    job = job_fixture(scope_for(c.qasim), team: c.backend, company: corvid)
    mei = contact_fixture(scope_for(c.fiza), name: "Mei Chen", company: corvid)

    {:ok, _} =
      Data.Contacts.link_lead(%{
        lead_id: lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang).id,
        contact_id: mei.id,
        role: :recruiter
      })

    Map.merge(c, %{fs: scope_for(c.fiza), corvid: corvid, job: job, mei: mei})
  end

  defp watch(scope, params, now \\ @now), do: Watches.create(scope, params, now)

  defp observe(c, attrs, at \\ @now) do
    {:ok, o} =
      Behaviour.observe(
        scope_for(c.qasim),
        Map.merge(%{source: :manual, observed_at: at, active_at: at, now: at}, attrs)
      )

    o
  end

  defp fired(user_id),
    do:
      Repo.all(
        from(n in Notification,
          where: n.user_id == ^user_id and n.notification_kind_key == "behaviour.watch_fired",
          order_by: [asc: n.inserted_at, asc: n.id]
        )
      )

  describe "making and changing" do
    test "201, then 200 for the same subject and trigger with its settings; the console's defaults",
         c do
      assert {:ok, {:created, w}} =
               watch(c.fs, %{"company_id" => c.corvid.id, "trigger" => "posts_job"})

      assert %{
               subject: %{kind: :company, name: "Corvid Security"},
               trigger: :posts_job,
               channels: [:push, :extension],
               cooldown_minutes: 120,
               expires_at: nil,
               paused_at: nil,
               is_expired: false
             } = w

      assert {:ok, {:updated, same}} =
               watch(c.fs, %{
                 "company_id" => c.corvid.id,
                 "trigger" => "posts_job",
                 "channels" => ["email"],
                 "expires_in" => "week"
               })

      assert same.id == w.id and same.channels == [:email] and same.cooldown_minutes == 120
      assert same.expires_at == DateTime.add(@now, 7 * 86_400, :second)
    end

    test "422: a trigger the subject doesn't take, channels, cool-down, expiry; 404 unseen", c do
      assert {:error,
              {:invalid, %{"trigger" => ["is one a company takes: posts_job, any_activity"]}}} =
               watch(c.fs, %{"company_id" => c.corvid.id, "trigger" => "replies"})

      assert {:error, {:invalid, %{"trigger" => [_]}}} =
               watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "posts_job"})

      base = %{"contact_id" => c.mei.id, "trigger" => "replies"}

      assert {:error, {:invalid, %{"channels" => _}}} =
               watch(c.fs, Map.put(base, "channels", ["sms"]))

      assert {:error, {:invalid, %{"cooldown_minutes" => ["is 30, 120 or 1440"]}}} =
               watch(c.fs, Map.put(base, "cooldown_minutes", 45))

      assert {:error, {:invalid, %{"expires_in" => _}}} =
               watch(c.fs, Map.put(base, "expires_in", "year"))

      lonely = company_fixture(c.org, name: "Nobody's Co")

      assert {:error, :not_found} =
               watch(c.fs, %{"company_id" => lonely.id, "trigger" => "posts_job"})

      assert {:error, :not_found} = watch(customer_scope_for(c.tanweer), base)
    end

    test "PATCH pauses and resumes; another person's is 404 to read, change and remove", c do
      {:ok, {:created, w}} = watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "replies"})

      assert {:ok, %{paused_at: @now}} = Watches.update(c.fs, w.id, %{"paused" => true}, @now)
      later = DateTime.add(@now, 60, :second)
      assert {:ok, %{paused_at: @now}} = Watches.update(c.fs, w.id, %{"paused" => true}, later)

      assert {:ok, %{paused_at: nil, cooldown_minutes: 30}} =
               Watches.update(c.fs, w.id, %{"paused" => false, "cooldown_minutes" => 30}, later)

      hira = scope_for(c.hira)
      assert {:error, :not_found} = Watches.update(hira, w.id, %{"paused" => true}, @now)
      assert {:error, :not_found} = Watches.delete(hira, w.id)
      assert {:ok, %{items: []}} = Watches.list(hira, @now)

      assert :ok = Watches.delete(c.fs, w.id)
      assert {:ok, %{items: []}} = Watches.list(c.fs, @now)
    end

    test "the list: the caller's own, the expired last", c do
      {:ok, {:created, soon}} =
        watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "replies", "expires_in" => "week"})

      {:ok, {:created, open}} =
        watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "comes_online"})

      in_a_fortnight = DateTime.add(@now, 14 * 86_400, :second)
      {:ok, %{items: items}} = Watches.list(c.fs, in_a_fortnight)
      assert Enum.map(items, & &1.id) == [open.id, soon.id]
      assert List.last(items).is_expired
    end

    test "a customer has no watches: the list is not found", c do
      assert {:error, :not_found} = Watches.list(customer_scope_for(c.tanweer), @now)
    end

    test "the extension's: push and the extension, 2 h, in a team the caller is in", c do
      ext = %{c.fs | via: :extension}

      assert {:ok, {:created, %{channels: [:push, :extension], cooldown_minutes: 120}}} =
               Log.watch(
                 ext,
                 %{
                   "team_id" => c.backend.id,
                   "contact_id" => c.mei.id,
                   "trigger" => "comes_online"
                 },
                 @now
               )

      assert {:error, :not_found} =
               Log.watch(
                 scope_for(c.bilal),
                 %{"team_id" => c.frontend.id, "contact_id" => c.mei.id, "trigger" => "replies"},
                 @now
               )
    end
  end

  describe "matching" do
    test "posts_job fires once per cool-down, to the watcher alone; a second job inside it doesn't",
         c do
      {:ok, {:created, w}} = watch(c.fs, %{"company_id" => c.corvid.id, "trigger" => "posts_job"})

      o =
        observe(c, %{company_id: c.corvid.id, kind: :job_posted, source: :job, job_id: c.job.id})

      assert [n] = fired(c.fiza.id)
      assert n.title == "Corvid Security posted a job: #{c.job.title}."
      assert n.link_path == "/companies/#{c.corvid.id}?tab=behaviour"
      assert n.dedupe_key == "watch:#{w.id}:#{o.id}"
      assert n.actor_user_id == c.qasim.id
      assert fired(c.qasim.id) == [] and fired(c.hira.id) == []

      # Inside two hours: nothing; past them: again.
      _ =
        observe(
          c,
          %{company_id: c.corvid.id, kind: :job_reposted},
          DateTime.add(@now, 3600, :second)
        )

      assert [_one] = fired(c.fiza.id)

      _ =
        observe(
          c,
          %{company_id: c.corvid.id, kind: :job_reposted},
          DateTime.add(@now, 7200, :second)
        )

      assert [_, _] = fired(c.fiza.id)

      # A kind the trigger doesn't take fires nothing.
      _ =
        observe(
          c,
          %{company_id: c.corvid.id, kind: :seen_online},
          DateTime.add(@now, 99_999, :second)
        )

      assert [_, _] = fired(c.fiza.id)
    end

    test "a company watch matches its own observations only, a contact watch its own", c do
      {:ok, _} = watch(c.fs, %{"company_id" => c.corvid.id, "trigger" => "any_activity"})
      _ = observe(c, %{contact_id: c.mei.id, kind: :seen_online})
      assert fired(c.fiza.id) == []
    end

    test "a paused or expired watch fires nothing", c do
      {:ok, {:created, w}} =
        watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "replies", "expires_in" => "week"})

      {:ok, _} = Watches.update(c.fs, w.id, %{"paused" => true}, @now)
      _ = observe(c, %{contact_id: c.mei.id, kind: :replied})
      assert fired(c.fiza.id) == []

      {:ok, _} = Watches.update(c.fs, w.id, %{"paused" => false}, @now)

      _ =
        observe(
          c,
          %{contact_id: c.mei.id, kind: :replied},
          DateTime.add(@now, 8 * 86_400, :second)
        )

      assert fired(c.fiza.id) == []
    end

    test "on the watch's channels; comes_online passes quiet hours, the rest wait", c do
      push_subscription_fixture(c.fiza)
      device_fixture(c.fs)

      {:ok, _} =
        Data.Accounts.put_settings(c.fiza.id, %{
          quiet_hours_start: ~T[22:00:00],
          quiet_hours_end: ~T[08:00:00]
        })

      {:ok, _} =
        watch(c.fs, %{
          "contact_id" => c.mei.id,
          "trigger" => "comes_online",
          "channels" => ["push"]
        })

      {:ok, _} =
        watch(c.fs, %{
          "contact_id" => c.mei.id,
          "trigger" => "replies",
          "channels" => ["email", "extension"]
        })

      # 23:00 in Karachi.
      night = ~U[2026-11-14 18:00:00.000000Z]
      _ = observe(c, %{contact_id: c.mei.id, kind: :seen_online, source: :extension}, night)
      _ = observe(c, %{contact_id: c.mei.id, kind: :replied}, night)

      [online, reply] = fired(c.fiza.id)

      assert online.title ==
               "Corvid Security's client is online on Upwork (Qasim has the room open)."

      assert [%{channel: :push, deferred: false, deliver_after: ^night}] =
               Deliveries.for_notification(online.id)

      # AQ-10B QP10b-6: quiet hours hold the pop-up, never the email.
      assert [%{channel: :email, deferred: false}, %{channel: :extension, deferred: true}] =
               Deliveries.for_notification(reply.id)
    end

    test "a reply links its lead", c do
      lead = lead_fixture(c.fs, team: c.backend, profile: c.golang)
      conv = conversation_fixture(c.fs, lead: lead)

      ours =
        message_fixture(c.fs, conversation: conv, sent_at: DateTime.add(@now, -3600, :second))

      theirs =
        message_fixture(c.fs, conversation: conv, contact: c.mei, parent: ours, sent_at: @now)

      {:ok, _} = watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "replies"})

      _ =
        observe(c, %{
          contact_id: c.mei.id,
          kind: :replied,
          source: :email,
          message_id: theirs.id,
          reply_delay_s: 3600
        })

      assert [n] = fired(c.fiza.id)
      assert n.link_path == "/leads/#{lead.id}" and n.lead_id == lead.id
      assert n.title =~ "Mei Chen replied on #{lead.job.title}"
    end
  end

  describe "AQ-10B G8, §5.7 B2" do
    defp watch_mei(c) do
      {:ok, {:created, w}} =
        watch(c.fs, %{"contact_id" => c.mei.id, "trigger" => "any_activity"})

      w
    end

    test "a watch doesn't fire for its watcher's own hand-logged observation", c do
      _ = watch_mei(c)

      {:ok, _} =
        Behaviour.observe(c.fs, %{
          contact_id: c.mei.id,
          kind: :seen_online,
          source: :manual,
          observed_at: @now,
          active_at: @now,
          now: @now
        })

      assert fired(c.fiza.id) == []

      # Someone else's by hand still fires it.
      _ = observe(c, %{contact_id: c.mei.id, kind: :seen_online}, DateTime.add(@now, 60, :second))
      assert [_] = fired(c.fiza.id)
    end

    test "a watch whose owner can no longer read its subject doesn't fire, and goes", c do
      w = watch_mei(c)

      :ok =
        Teams.remove_member(scope_for(c.dawud), c.backend.id, c.fiza.id, @now)

      :ok =
        Teams.remove_member(scope_for(c.dawud), c.frontend.id, c.fiza.id, @now)

      _ = observe(c, %{contact_id: c.mei.id, kind: :seen_online})

      assert fired(c.fiza.id) == []
      assert Data.Watches.get_own(c.fiza.id, w.id) == nil
    end

    test "Forget tells each watcher their watch was removed", c do
      _ = watch_mei(c)
      {:ok, _} = Privacy.forget_contact(scope_for(c.hira), c.mei.id, @now)

      assert [%{title: "Your watch on Mei Chen was removed: they were forgotten"}] =
               Repo.all(
                 from(n in Notification,
                   where:
                     n.user_id == ^c.fiza.id and
                       n.notification_kind_key == "behaviour.watch_ending"
                 )
               )
    end
  end
end
