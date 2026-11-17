defmodule Notifire.Emails.Gallery do
  @moduledoc """
  `/dev/emails` (AQ-10B §7.3, §11.4): every template rendered with sample
  data, staff and customer, HTML and plain text, the customer with no
  portal login where they are mailed — for a person to look at and a run
  to screenshot, on a **dev server only** (`ApiTeam.DevEmailController`).
  Nothing here reads the database: the samples are words, the footer a
  sample organisation's.
  """

  import Notifire.Emails.Html, only: [escape: 1]

  require EEx

  alias Data.Seeds.Notifications, as: Seed
  alias Notifire.Emails.{Renderer, Templates, Why}

  @index Path.expand("../../../priv/emails/_gallery/index.html.eex", __DIR__)
  EEx.function_from_file(:defp, :index_html, @index, [:assigns])

  @no_login ~w(meetings.scheduled meetings.changed meetings.day_before leads.customer_milestone
               leads.weekly_report)

  @mails %{
    "account.invitation" => "Invitation",
    "account.invitation_reminder" => "Invitation reminder",
    "account.password_reset" => "Password reset",
    "account.email_change" => "Confirm a new email",
    "account.email_change_notice" => "Email change asked (old address)",
    "account.email_changed" => "Email changed (old address)"
  }

  @doc "The index page: a row per kind × audience, linking HTML, plain text and no-login."
  @spec index(String.t()) :: String.t()
  def index(base) do
    rows =
      for {kind, audience} <- Templates.sets() ++ [{"_fallback", "staff"}] do
        link = "#{base}/#{kind}?audience=#{audience}"

        %{
          kind: kind,
          label: Map.get(@mails, kind) || label(kind),
          audience: audience,
          html: link <> "&format=html",
          text: link <> "&format=text",
          no_login:
            audience == "customer" and kind in @no_login and link <> "&format=html&no_login=1"
        }
      end

    index_html(%{rows: rows})
  end

  defp label("_fallback"), do: "A kind with no template of its own"
  defp label(kind), do: Seed.label(kind)

  @doc """
  One kind rendered with sample data: `%{subject, html, text}`, or `nil`
  for a kind with no template for that audience (the fallback is shown as
  `_fallback`).
  """
  @spec render(String.t(), String.t(), boolean()) :: map() | nil
  def render(kind, audience, no_login? \\ false) do
    if Templates.has?(kind, audience) or kind == "_fallback" do
      customer? = audience == "customer"
      no_login? = no_login? and customer?

      Renderer.render(
        kind,
        audience,
        content(kind, customer?, no_login?),
        chrome(kind, customer?, no_login?)
      )
    end
  end

  defp chrome(kind, customer?, no_login?) do
    locked? = kind in Seed.locked()
    mail? = Map.has_key?(@mails, kind)
    manage? = not no_login? and kind != "account.invitation"
    unsubscribe? = not (locked? or mail? or no_login?)

    %{
      org_name: "Northwind Talent",
      why: why(kind, customer?, no_login?, mail?),
      manage_url: if(manage?, do: app(customer?) <> "/notifications?sheet=settings"),
      unsubscribe_url: if(unsubscribe?, do: app(customer?) <> "/unsubscribe?token=sample-token"),
      group_label: kind |> String.split(".") |> hd() |> Seed.group_label(),
      locked_note: if(locked?, do: "You can't turn these off: they keep your account safe."),
      help_email: "help@northwind.example",
      postal_address: "12 Mall Road, Lahore 54000, Pakistan"
    }
  end

  defp why(kind, _customer?, _no_login?, true),
    do: "this is a sample of #{Map.fetch!(@mails, kind)}."

  defp why(_kind, _customer?, true, _mail?),
    do: "your team at Northwind Talent is looking for work for you."

  defp why(kind, customer?, false, false), do: Why.line(kind, customer?)

  defp app(true), do: "http://localhost:5801"
  defp app(false), do: "http://localhost:5800"

  # ── The samples ─────────────────────────────────────────────────────────────

  defp content(kind, customer?, no_login?) do
    base = %{
      first_name: if(customer?, do: "Tanweer", else: "Fiza"),
      url: unless(no_login?, do: app(customer?) <> "/notifications?n=sample"),
      facts: facts(kind, customer?),
      no_login: no_login?
    }

    Map.merge(base, words(kind, customer?))
  end

  defp facts("leads." <> _rest, customer?), do: lead_facts(customer?)
  defp facts("conversations.reply_received", customer?), do: lead_facts(customer?)
  defp facts("meetings." <> _rest, customer?), do: lead_facts(customer?)

  defp facts("tasks." <> _rest, _customer?),
    do: [{"Task", "Send the updated CV"}, {"Due", "Wed 18 Nov"}]

  defp facts("approvals." <> _rest, _customer?),
    do: [{"Approval", "Reply to Mei Chen"}, {"Due", "Thu 19 Nov, 09:00 UTC"}]

  defp facts(_kind, _customer?), do: []

  defp lead_facts(customer?) do
    [
      {"Role", "Backend Developer"},
      {"Company", "Corvid Security"},
      {"Profile", unless(customer?, do: "Golang backend")},
      {"Customer", unless(customer?, do: "Tanweer Ahmed")},
      {"Stage", "Technical interview 1"}
    ]
  end

  @meeting "Technical interview with Corvid Security · Wed 18 Nov 14:00 PKT"

  defp words("tasks.assigned", true), do: %{title: "Fiza gave you “Send the updated CV”"}

  defp words("tasks.assigned", false),
    do: %{title: "Hira gave you “Shortlist three Go roles”", body: "A step of “Tanweer’s week”"}

  defp words("tasks.commented", _c),
    do: %{
      title: "Fiza commented on “Send the updated CV”",
      body: "Thanks, this version reads much better. One last change to the summary?"
    }

  defp words("tasks.mentioned", _c),
    do: %{
      title: "Hira mentioned you on “Shortlist three Go roles”",
      body: "@Fiza can you check the Corvid one before Friday?"
    }

  defp words("tasks.overdue", _c), do: %{title: "Overdue: “Send the updated CV”"}

  defp words("tasks.nudged", _c),
    do: %{
      title: "Fiza nudged you about “Upload your references”",
      body: "A step of “Apply to Corvid”"
    }

  defp words("leads.customer_milestone", _c),
    do: %{
      title:
        "The team moved your application to “Backend Developer” at Corvid Security to Technical interview 1.",
      body: "Your team will be in touch with the details."
    }

  defp words("leads.weekly_report", _c),
    do: %{
      title: "Your week: 8 applications, 2 replies, 1 interview",
      body: "Next: 2 meetings in the week ahead."
    }

  defp words("conversations.forwarding_confirm", _c),
    do: %{title: "Gmail sent a forwarding code for tanweer@gmail.com", body: "Code: 728193"}

  defp words("conversations.forwarding_silent", true),
    do: %{
      title: "No mail has reached your team since 30 Oct",
      body: "Check that your Gmail still forwards to your team's address."
    }

  defp words("conversations.forwarding_silent", false),
    do: %{
      title: "No mail from Tanweer Ahmed's Gmail since 30 Oct",
      body: "Check that Gmail still forwards to Tanweer Ahmed's address."
    }

  defp words("meetings.scheduled", true),
    do: %{
      title: "The team scheduled " <> @meeting,
      body:
        "When: Wed 18 Nov 14:00 PKT\nWhere: Google Meet\nJoin: https://meet.google.com/abc-defg-hij"
    }

  defp words("meetings.scheduled", false), do: %{title: "Hira scheduled " <> @meeting}

  defp words("meetings.changed", _c),
    do: %{title: "Technical interview with Corvid Security moved to Thu 19 Nov 15:00 PKT"}

  defp words("meetings.day_before", _c),
    do: %{title: "Technical interview with Corvid Security in 24 hours · 14:00 PKT · Google Meet"}

  defp words("approvals.requested", true),
    do: %{title: "Fiza asks for your approval: Reply to Mei Chen"}

  defp words("approvals.requested", false),
    do: %{title: "Hira asks for your approval: Proposal for the Upwork Go job"}

  defp words("approvals.decided", _c),
    do: %{
      title: "Tanweer asked for changes to Reply to Mei Chen",
      body: "Please mention I can start in January."
    }

  defp words("approvals.commented", _c),
    do: %{
      title: "Fiza commented on Reply to Mei Chen",
      body: "I've softened the second paragraph."
    }

  defp words("approvals.overdue", _c), do: %{title: "Overdue: Reply to Mei Chen"}
  defp words("approvals.expired", _c), do: %{title: "Reply to Mei Chen expired with no decision"}

  defp words("behaviour.watch_fired", _c),
    do: %{
      title: "Mei Chen is online on LinkedIn now",
      body: "Seen from the extension a minute ago."
    }

  defp words("system.selectors_failing", _c),
    do: %{
      title: "LinkedIn's selectors missed 42 times today",
      body: "LinkedIn may have changed its pages. Check the extension's health."
    }

  defp words("system.delivery_failing", _c), do: %{title: "14 deliveries failed in the last hour"}

  defp words("system.inbound_failing", _c),
    do: %{title: "7 forwarded mails failed in the last hour"}

  defp words("system.jobs_discarded", _c),
    do: %{
      title: "2 background jobs gave up in the last hour",
      body: "DeliveryWorker, InboundSweep"
    }

  defp words("account.welcome", true),
    do: %{
      title: "Welcome to AutoQare",
      body:
        "Your team shares your applications, tasks and meetings here. Add the portal to your Home Screen to get push on your phone."
    }

  defp words("account.welcome", false),
    do: %{
      title: "Welcome to AutoQare",
      body: "Connect the Chrome extension and turn on push, so replies and meetings reach you."
    }

  defp words("account.security", _c),
    do: %{
      title: "Your password was changed",
      body: "If this wasn't you, reset it now and tell your team."
    }

  defp words("account.team_changed", _c),
    do: %{title: "Hira made you a team lead of Backend squad"}

  defp words("account.extension_connected", _c),
    do: %{title: "The extension connected to your account", body: "Chrome on macOS"}

  defp words("account.extension_off", _c),
    do: %{title: "Hira disconnected your extension", body: "Chrome on Windows"}

  defp words("account.weekly_summary", _c),
    do: %{
      title: "Your team's week: 30 applications, 8 replies, 3 meetings",
      body:
        "Backend squad: 30 applications, 8 replies, 3 meetings\nNext: 4 meetings in the week ahead."
    }

  defp words("account.digest", _c),
    do: %{
      title: "5 things waiting for you",
      body: "Tasks · 2\nLeads · 3",
      items: [
        "Due tomorrow: “Send the updated CV”",
        "Overdue: “Upload your references”",
        "Follow up on “Backend Developer · Corvid Security”",
        "“Go Engineer · Bamboo Invest” has sat in To do for a week",
        "“Platform Engineer · Lumen” will be archived on 21 Nov"
      ]
    }

  defp words("account.invitation", true),
    do: %{
      title: "Hira invited you to Northwind Talent",
      body: "Hira invited you to Northwind Talent to see your job search.",
      expires_on: "21 Nov"
    }

  defp words("account.invitation", false),
    do: %{
      title: "Hira invited you to Northwind Talent",
      body: "Hira invited you to Northwind Talent as a team member of Backend squad.",
      expires_on: "21 Nov"
    }

  defp words("account.invitation_reminder", c),
    do: "account.invitation" |> words(c) |> Map.update!(:title, &("Reminder: " <> &1))

  defp words("account.password_reset", _c), do: %{title: "Reset your AutoQare password"}
  defp words("account.email_change", _c), do: %{title: "Confirm your new email for AutoQare"}

  defp words("account.email_change_notice", _c),
    do: %{
      title: "Your AutoQare email is changing",
      body: "Someone asked to move your account to fiza.k@example.com."
    }

  defp words("account.email_changed", _c),
    do: %{
      title: "Your AutoQare email changed",
      body: "Your account now signs in with fiza.k@example.com."
    }

  defp words(kind, _c), do: %{title: Seed.label(kind) <> ": a sample notice"}
end
