defmodule Core.Conversations.NoticesTest do
  @moduledoc """
  AQ-10B §5.6 through the conversation verbs: a reply told to the lead's
  watchers too (QP10b-15); a hand-typed message that starts a team's
  conversation new in Triage, as mail is (G8); an unsubscribe classified
  told to the owners of the contact's leads.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.{Classify, Messages}
  alias Data.Notifications.{LeadWatchers, Notification}

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    mei = contact_fixture(fiza, name: "Mei Chen", handles: [{:email, "mei@corvid.example"}])
    Map.merge(c, %{fiza_s: fiza, lead: lead, mei: mei})
  end

  defp rows(user_id, kind) do
    from(n in Notification, where: n.user_id == ^user_id and n.notification_kind_key == ^kind)
    |> Repo.all()
  end

  test "a reply on a lead is told to its owner and its watchers", c do
    :ok = LeadWatchers.watch(c.lead.id, c.muaz.id, @now)

    {:ok, _} =
      Messages.create(
        scope_for(c.hira),
        %{
          "lead_id" => c.lead.id,
          "platform" => "email",
          "direction" => "in",
          "from" => %{"kind" => "contact", "contact_id" => c.mei.id},
          "sent_at" => "2026-11-14T08:00:00Z",
          "body_md" => "Are you free on Tuesday?"
        },
        @now
      )

    assert [%{title: "Mei Chen replied on " <> _}] =
             rows(c.fiza.id, "conversations.reply_received")

    assert [_] = rows(c.muaz.id, "conversations.reply_received")
  end

  test "a hand-typed message that starts a team's conversation is new in Triage", c do
    {:ok, _} =
      Messages.create(
        c.fiza_s,
        %{
          "team_id" => c.backend.id,
          "platform" => "linkedin",
          "direction" => "in",
          "from" => %{"kind" => "text", "text" => "Omar Haddad"},
          "sent_at" => "2026-11-14T08:00:00Z",
          "body_md" => "Hello, are you open to a role?",
          "subject" => "Platform role"
        },
        @now
      )

    for leader <- [c.hira, c.bilal] do
      assert [%{title: "New in Triage: Omar Haddad · Platform role"}] =
               rows(leader.id, "conversations.triage_new")
    end

    assert rows(c.fiza.id, "conversations.triage_new") == []
  end

  test "an unsubscribe classified tells the owners of the contact's leads", c do
    {:ok, _} =
      LeadLinks.link(
        c.fiza_s,
        c.lead.id,
        %{"contact_id" => c.mei.id, "role" => "recruiter"},
        @now
      )

    conv = conversation_fixture(c.fiza_s, lead: c.lead)

    msg =
      message_fixture(c.fiza_s,
        conversation: conv,
        contact: c.mei,
        direction: :in,
        body_text: "Please remove me from your list."
      )

    {:ok, _} = Classify.run(scope_for(c.hira), msg.id, %{"class" => "unsubscribe"}, @now)

    assert [%{title: "Mei Chen unsubscribed: marked do-not-contact"}] =
             rows(c.fiza.id, "conversations.contact_flagged")
  end
end
