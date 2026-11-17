defmodule Notifire.DeliveryTest do
  @moduledoc """
  The far side of the seam (AQ-08 §7.2, §11.4), against a real database
  and the test mailbox. Nothing here goes through `core`: the rows are
  written as the seam writes them (`delivery_fixture/2`), and delivery only
  ever sees rows. **Every run twice.**
  """

  use Notifire.NotifireCase, async: true

  # A refused email logs a warning, as it should; not in the test output.
  @moduletag :capture_log

  alias Data.Notifications.{CustomerMails, Deliveries, Delivery, KindPreferences}
  alias Notifire.Delivery, as: Sweep
  alias Notifire.Push.Outbox

  @now ~U[2026-11-12 06:00:00.000000Z]

  setup do
    org = organisation_fixture()
    fiza = user_fixture(display_name: "Fiza Malik", email: "fiza@example.com")
    customer = customer_fixture(org, [], login: true, login_name: "Muhammad Tanweer")
    tanweer = Data.Accounts.get_user(customer.user_id)
    %{org: org, fiza: fiza, tanweer: tanweer}
  end

  defp notice(c, user, kind, attrs \\ %{}) do
    notification_fixture(
      c.org,
      user,
      Map.merge(
        %{
          notification_kind_key: kind,
          title: "Hira asked you to approve “Golang CV”",
          body: "Before Friday, please.",
          link_path: "/approvals/7?team=3"
        },
        attrs
      )
    )
  end

  defp state(row), do: Repo.get!(Delivery, row.id)

  describe "email" do
    test "sent once, when due, in the row's words, with the link into the console and the footer",
         c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: DateTime.add(@now, 600, :second))

      # Inside its ten minutes: not yet.
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      refute_email_sent()

      at = DateTime.add(@now, 601, :second)
      assert Sweep.run(at) == %{sent: 1, skipped: 0, failed: 0}
      assert Sweep.run(at) == %{sent: 0, skipped: 0, failed: 0}

      # AQ-10B §7: designed, from "<Organisation> via AutoQare", with the
      # footer's links and the one-click unsubscribe headers.
      assert_email_sent(fn email ->
        assert email.to == [{"Fiza Malik", "fiza@example.com"}]
        assert email.from == {"#{c.org.name} via AutoQare", "notifications@autoqare.com"}
        assert email.subject == "Hira asked you to approve “Golang CV”"
        assert email.reply_to == nil
        assert email.headers["X-AQ-Kind"] == "approvals.requested"
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
        assert email.headers["List-Unsubscribe"] =~ "<http://localhost:4100/unsubscribe?token="
        assert email.html_body =~ "Hira asked you to approve “Golang CV”"
        assert email.text_body =~ "Hi Fiza,"
        assert email.text_body =~ "Before Friday, please."
        assert email.text_body =~ "http://localhost:5800/approvals/7?team=3&n=#{n.id}"

        assert email.text_body =~
                 "Manage notifications: http://localhost:5800/notifications?sheet=settings"

        assert email.text_body =~
                 "Unsubscribe from Approvals: http://localhost:5800/unsubscribe?token="
      end)

      assert %{state: :sent, sent_at: ^at} = state(row)
    end

    test "a customer's opens the portal; with no body the title stands in", c do
      n =
        notice(c, c.tanweer, "leads.customer_milestone", %{
          body: nil,
          title: "The team moved your application to Offer.",
          link_path: "/applications/9"
        })

      delivery_fixture(n, channel: :email, deliver_after: @now)

      assert %{sent: 1} = Sweep.run(@now)

      assert_email_sent(fn email ->
        assert email.subject == "The team moved your application to Offer."
        assert email.text_body =~ "The team moved your application to Offer."
        assert email.text_body =~ "http://localhost:5801/applications/9?n=#{n.id}"
        assert email.text_body =~ "http://localhost:5801/notifications?sheet=settings"
      end)
    end

    test "read before its time, it is skipped; a meeting's still goes, with its invite", c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.fiza.id, n.id, @now)

      meeting =
        notice(c, c.fiza, "meetings.scheduled", %{title: "Hira scheduled Technical interview"})

      ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
      invite = delivery_fixture(meeting, channel: :email, deliver_after: @now, ics: ics)
      Data.Notifications.mark_read(c.fiza.id, meeting.id, @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :read} = state(row)
      assert %{state: :sent} = state(invite)

      assert_email_sent(fn email ->
        assert email.subject == "Hira scheduled Technical interview"
        assert [attachment] = email.attachments
        assert attachment.filename == "invite.ics"
        assert attachment.content_type == "text/calendar; method=REQUEST"
        assert attachment.data == ics
      end)
    end

    test "the digest goes even when read, with its lines, its link and its frequency", c do
      {:ok, _} = Data.Accounts.put_settings(c.fiza.id, %{digest_frequency: :weekly})

      n =
        notice(c, c.fiza, "account.digest", %{
          title: "2 things waiting for you",
          body: "Tasks · 2\n\nA is overdue\nB is overdue",
          link_path: "/notifications?unread=1"
        })

      delivery_fixture(n, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.fiza.id, n.id, @now)

      assert %{sent: 1} = Sweep.run(@now)

      assert_email_sent(fn email ->
        assert email.subject == "2 things waiting for you"
        assert email.text_body =~ "Tasks · 2\n\n- A is overdue\n- B is overdue"

        assert email.text_body =~
                 "Open your notifications: http://localhost:5800/notifications?unread=1"

        assert email.text_body =~ "you get a weekly digest"
        assert email.html_body =~ "A is overdue"
      end)
    end

    test "a refusal is recorded, never swallowed: retried on the next two sweeps, then failed",
         c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      failing = [mailer: [adapter: Notifire.FailingAdapter]]

      assert Sweep.run(@now, failing) == %{sent: 0, skipped: 0, failed: 1}
      retry = DateTime.add(@now, 300, :second)

      assert %{state: :pending, attempts: 1, error: "mailbox unavailable", deliver_after: ^retry} =
               state(row)

      # Not due again until five minutes on.
      assert Sweep.run(@now, failing) == %{sent: 0, skipped: 0, failed: 0}
      assert Sweep.run(retry, failing) == %{sent: 0, skipped: 0, failed: 1}
      last = DateTime.add(retry, 300, :second)
      assert Sweep.run(last, failing) == %{sent: 0, skipped: 0, failed: 1}
      assert %{state: :failed, attempts: 3, error: "mailbox unavailable"} = state(row)

      assert Sweep.run(DateTime.add(last, 3600, :second), failing) == %{
               sent: 0,
               skipped: 0,
               failed: 0
             }
    end
  end

  describe "preferences at send time" do
    test "a channel turned off since the row was planned is skipped; a locked kind can't be", c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      preference_fixture(c.fiza, "approvals", %{email: false})

      # AQ-10B QP10b-4: Account can be switched off now; its locked kinds can't.
      security = notice(c, c.fiza, "account.security", %{title: "Your password was changed"})
      kept = delivery_fixture(security, channel: :email, deliver_after: @now)
      preference_fixture(c.fiza, "account", %{email: false})

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :preference_off} = state(row)
      assert %{state: :sent} = state(kept)

      assert_email_sent(fn email ->
        assert email.from == {"#{c.org.name} via AutoQare", "hello@autoqare.com"}
        assert email.headers["List-Unsubscribe"] == nil
        refute email.text_body =~ "Unsubscribe"
        assert email.text_body =~ "You can't turn these off"
      end)
    end

    test "a kind switched off since is skipped; the group's other kinds still go", c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      other = notice(c, c.fiza, "approvals.overdue")
      sent = delivery_fixture(other, channel: :email, deliver_after: @now)

      {:ok, _} =
        KindPreferences.put(
          c.fiza.id,
          "approvals.requested",
          %{push: true, email: false, extension: true, digest: true},
          @now
        )

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :preference_off} = state(row)
      assert %{state: :sent} = state(sent)
    end

    test "a customer's email isn't skipped when read; a staff member's is", c do
      mine = notice(c, c.tanweer, "tasks.commented", %{title: "Fiza commented"})
      theirs = delivery_fixture(mine, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.tanweer.id, mine.id, @now)

      staff = notice(c, c.fiza, "tasks.assigned", %{title: "Hira gave you a task"})
      skipped = delivery_fixture(staff, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.fiza.id, staff.id, @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :sent} = state(theirs)
      assert %{state: :skipped, skip_reason: :read} = state(skipped)
    end
  end

  describe "push (test records, never sends)" do
    test "sent to the person's browsers on their app, kept in the outbox; the tag is the notification",
         c do
      push_subscription_fixture(c.fiza, app: :team, endpoint: "https://push.example/fiza-team")

      push_subscription_fixture(c.fiza,
        app: :client,
        endpoint: "https://push.example/fiza-client"
      )

      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :push, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 0, failed: 0}
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      assert %{state: :sent} = state(row)

      assert [%{app: :team, endpoint: "https://push.example/fiza-team", payload: payload}] =
               Enum.filter(Outbox.list(), &(&1.user_id == c.fiza.id))

      assert payload == %{
               title: "Hira asked you to approve “Golang CV”",
               body: "Before Friday, please.",
               tag: n.id,
               url: "/approvals/7?team=3&n=#{n.id}"
             }
    end

    test "nowhere to send it: skipped, no target; a customer's goes to the portal's browsers",
         c do
      n = notice(c, c.fiza, "tasks.assigned")
      row = delivery_fixture(n, channel: :push, deliver_after: @now)

      push_subscription_fixture(c.tanweer, app: :client, endpoint: "https://push.example/tanweer")
      milestone = notice(c, c.tanweer, "leads.customer_milestone", %{link_path: nil})
      told = delivery_fixture(milestone, channel: :push, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :no_target} = state(row)
      assert %{state: :sent} = state(told)

      assert [%{app: :client, payload: %{url: url}}] =
               Enum.filter(Outbox.list(), &(&1.user_id == c.tanweer.id))

      assert url == "/notifications?n=#{milestone.id}"
    end
  end

  describe "the extension's rows" do
    test "nobody claimed within a day: skipped, no target; younger ones wait for the poll", c do
      n = notice(c, c.fiza, "conversations.reply_received")

      old =
        delivery_fixture(n,
          channel: :extension,
          deliver_after: DateTime.add(@now, -86_401, :second)
        )

      fresh =
        notice(c, c.fiza, "conversations.reply_received")
        |> delivery_fixture(channel: :extension, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 0, skipped: 1, failed: 0}
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      assert %{state: :skipped, skip_reason: :no_target} = state(old)
      assert %{state: :pending} = state(fresh)
      assert length(Deliveries.for_user(c.fiza.id)) == 2
    end
  end

  describe "a customer with no portal login (AQ-10B QP10b-2)" do
    test "their mail goes once, designed, with the invite and Reply-To the profile's owner", c do
      sara = customer_fixture(c.org, [], display_name: "Sara Ali", email: "sara@example.com")
      profile_fixture(sara, title: "Sara's CV", owners: [c.fiza])

      {:new, row} =
        CustomerMails.ensure(
          %{
            organisation_id: c.org.id,
            customer_id: sara.id,
            kind_key: "meetings.scheduled",
            dedupe_key: "mail:meeting:1:0",
            to_email: "sara@example.com",
            subject:
              "The team scheduled Technical interview with Corvid Security · Wed 18 Nov 14:00 PKT",
            text: "When: Wed 18 Nov 14:00 PKT\nWhere: Google Meet",
            ics: "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
          },
          @now
        )

      assert %{sent: 1} = Sweep.run(@now)
      assert %{sent: 0} = Sweep.run(@now)

      assert_email_sent(fn email ->
        assert email.to == [{"Sara Ali", "sara@example.com"}]
        assert email.reply_to == {"Fiza Malik", "fiza@example.com"}
        assert email.subject =~ "Technical interview with Corvid Security"
        assert email.text_body =~ "Hi Sara,"
        assert email.text_body =~ "Ask your team for a portal invitation to see everything."
        assert email.headers["X-AQ-Kind"] == "meetings.scheduled"
        assert [%{filename: "invite.ics"}] = email.attachments
      end)

      sent = Repo.get!(Data.Notifications.CustomerMail, row.id)
      assert sent.state == :sent and sent.html =~ "<!DOCTYPE html>"
    end

    test "a customer who has a login by now is skipped", c do
      customer = Data.Customers.get_by_user(c.tanweer.id)

      {:new, row} =
        CustomerMails.ensure(
          %{
            organisation_id: c.org.id,
            customer_id: customer.id,
            kind_key: "leads.weekly_report",
            dedupe_key: "weekly:x",
            to_email: "t@example.com",
            subject: "Your week",
            text: "x"
          },
          @now
        )

      assert %{skipped: 1} = Sweep.run(@now)
      assert Repo.get!(Data.Notifications.CustomerMail, row.id).state == :skipped
    end
  end
end
