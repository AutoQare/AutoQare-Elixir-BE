defmodule Notifire.EmailTest do
  use Notifire.NotifireCase, async: true

  alias Notifire.Email

  @now ~U[2026-11-09 10:00:00.000000Z]

  test "the invitation names who, what and the console link" do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org, name: "Backend squad")
    inviter = admin_fixture(org)

    inv =
      invitation_fixture(org,
        team: team,
        role: :lead,
        email: "hira@example.com",
        invited_by_user_id: inviter.id
      )

    inv = Data.Invitations.get_for_system(inv.id)

    mail = Email.invitation(inv)
    assert mail.to == [{"Invited Person", "hira@example.com"}]
    assert mail.subject == "Test Person invited you to Regbits BD"
    assert mail.from == {"Regbits BD via AutoQare", "hello@autoqare.com"}
    assert mail.text_body =~ "as a team lead of Backend squad"
    assert mail.text_body =~ "http://localhost:5800/invite/#{inv.code}"
    assert mail.html_body =~ ~s(href="http://localhost:5800/invite/#{inv.code}")
    assert mail.headers["X-AQ-Kind"] == "account.invitation"
    assert mail.headers["List-Unsubscribe"] == nil
  end

  test "an admin invitation with no inviter is from the organisation" do
    org = organisation_fixture(name: "Regbits BD")

    inv =
      org
      |> invitation_fixture(invited_name: nil)
      |> then(&Data.Invitations.get_for_system(&1.id))

    mail = Email.invitation(inv)
    assert mail.subject == "Regbits BD invited you to Regbits BD"
    assert mail.text_body =~ "as the system admin"
    assert [{_no_name, address}] = mail.to
    assert address == inv.email
  end

  test "the reset carries the token in a visible link and says how long it lasts" do
    user = user_fixture()
    {:ok, {token, row}} = Data.Accounts.create_token(user, :reset_password, @now)
    mail = Email.password_reset(row, token)
    assert mail.to == [{"Test Person", user.email}]
    assert mail.text_body =~ "reset-password?token=#{URI.encode(token)}"
    assert mail.text_body =~ "an hour"
  end

  test "the email change goes to the new address, never the old" do
    user = user_fixture()

    {:ok, {token, row}} =
      Data.Accounts.create_token(user, :change_email, @now, new_email: "new@example.com")

    mail = Email.email_change(row, token)
    assert mail.to == [{"Test Person", "new@example.com"}]
    assert mail.text_body =~ "confirm-email?token="
    # AQ-10B G1: the old typo is gone.
    refute mail.text_body =~ "a AutoQare"
    assert mail.text_body =~ "an AutoQare account"
  end

  test "the old address is told when a change is asked, and when it is done" do
    user = user_fixture()

    {:ok, {token, row}} =
      Data.Accounts.create_token(user, :change_email, @now, new_email: "new@example.com")

    notice = Email.email_change_notice(row, token)
    assert notice.to == [{"Test Person", user.email}]
    assert notice.subject == "Your AutoQare email is changing"
    assert notice.text_body =~ "new@example.com"

    done = Email.email_changed(user, "old@example.com", "new@example.com")
    assert done.to == [{"Test Person", "old@example.com"}]
    assert done.text_body =~ "now signs in with new@example.com"
  end

  # AQ-08 §7.7, §11.4: the delivery tests read the whole form from the
  # mailbox; here, what only the builder shows.
  test "a notification: the subject on one line; a cancelled meeting's invite is a CANCEL" do
    user = user_fixture(display_name: "Hira Khan")
    recipient = Data.Notifications.recipient(user.id)

    notification = %{
      id: "n1",
      organisation_id: nil,
      user_id: user.id,
      lead_id: nil,
      task_id: nil,
      approval_id: nil,
      notification_kind_key: "meetings.changed",
      notification_kind: Data.Notifications.get_kind("meetings.changed"),
      title: "Technical interview with Corvid Security\nwas cancelled",
      body: nil,
      link_path: "/leads/1"
    }

    mail =
      Email.for_notification(notification, recipient, "METHOD:CANCEL\r\nSTATUS:CANCELLED\r\n")

    assert mail.subject == "Technical interview with Corvid Security was cancelled"
    assert mail.to == [{"Hira Khan", user.email}]

    assert [%{content_type: "text/calendar; method=CANCEL", filename: "invite.ics"}] =
             mail.attachments

    assert mail.text_body =~ "http://localhost:5800/leads/1?n=n1"

    assert Email.for_notification(notification, recipient).attachments == []
  end
end
