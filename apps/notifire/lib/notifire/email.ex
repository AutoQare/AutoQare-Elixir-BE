defmodule Notifire.Email do
  @moduledoc """
  Every email AutoQare sends, **designed as one family** (AQ-10B §7,
  §11.4, QP10b-7…10): HTML and plain text from the template files
  (`Notifire.Emails.Renderer`), the organisation's name and the mark in the
  header, the footer (why you got this, *Manage notifications*, one-click
  unsubscribe from that group, the help address and postal address when
  set, "Sent by AutoQare for <organisation>").

  - **P1's mails** (`invitation/1`, `password_reset/2`, `email_change/2`)
    and the account's direct mails (`invitation_reminder/2`,
    `email_change_notice/2` to the old address when a change is asked,
    `email_changed/3` to the old address when it is done);
  - **a notification** (`for_notification/4`), in the row's own words —
    already in the recipient's terms — with the subject's facts and a
    meeting's `invite.ics`;
  - **a customer with no portal login** (`for_customer_mail/2`, QP10b-2).

  **Headers:** `From: "<Organisation> via AutoQare"
  <notifications@autoqare.com>` (account mail — P1's, the direct ones, a
  locked kind — from `hello@`); `Reply-To` the profile's first owner on a
  customer's mail; `List-Unsubscribe` (the backend's `POST /unsubscribe`
  with a 60-day token, and a `mailto:`) and `List-Unsubscribe-Post:
  List-Unsubscribe=One-Click` on notification mail, never on a locked
  kind's or account mail; `X-AQ-Kind` always.

  The addresses and the app URLs are config (`:notifire`), read at send
  time.
  """

  import Swoosh.Email

  alias Data.Accounts.UserToken
  alias Data.Invitations.Invitation
  alias Data.Notifications.{Mail, Notification, Unsubscribe}
  alias Data.Seeds.Notifications, as: Seed
  alias Notifire.Emails.{Renderer, Why}

  @locked_note "You can't turn these off: they keep your account safe."

  # ── P1's mails and the account's direct ones ────────────────────────────────

  @doc "The invitation (AQ-01 §3): who invited you, to what, and the link."
  @spec invitation(Invitation.t()) :: Swoosh.Email.t()
  def invitation(%Invitation{} = invitation), do: invite_mail(invitation, "account.invitation")

  @doc """
  The reminder of an unanswered invitation (AQ-10B §5 A2): three days on,
  and the day before it expires.
  """
  @spec invitation_reminder(Invitation.t(), DateTime.t()) :: Swoosh.Email.t()
  def invitation_reminder(%Invitation{} = invitation, _now),
    do: invite_mail(invitation, "account.invitation_reminder")

  defp invite_mail(invitation, kind) do
    who = inviter(invitation)
    org = Mail.organisation(invitation.organisation_id) || %{name: invitation.organisation.name}
    audience = if invitation.kind == :customer, do: "customer", else: "staff"

    title =
      if kind == "account.invitation_reminder",
        do: "Reminder: #{who} invited you to #{org.name}",
        else: "#{who} invited you to #{org.name}"

    rendered =
      Renderer.render(
        kind,
        audience,
        %{
          first_name: first_word(invitation.invited_name),
          title: title,
          body: "Join #{org.name} #{as_what(invitation)}.",
          url: accept_url(invitation),
          expires_on: Calendar.strftime(invitation.expires_at, "%-d %b")
        },
        chrome(org, "#{who} invited this address to #{org.name}.", nil)
      )

    new()
    |> to(recipient(invitation.invited_name, invitation.email))
    |> from(account_sender(org))
    |> put(rendered, kind)
  end

  defp as_what(%Invitation{kind: :admin}), do: "as the system admin"
  defp as_what(%Invitation{kind: :team_member} = i), do: "as a team #{i.role} of #{i.team.name}"
  defp as_what(%Invitation{kind: :customer}), do: "to see your job search"

  defp inviter(%Invitation{invited_by_user: %{person: %{display_name: name}}}), do: name
  defp inviter(%Invitation{organisation: %{name: name}}), do: name

  @doc "The password reset link: the only mail that carries a credential."
  @spec password_reset(UserToken.t(), String.t()) :: Swoosh.Email.t()
  def password_reset(%UserToken{user: user}, token) do
    org = Mail.organisation_of_user(user.id)
    app = app_url(user.id)

    rendered =
      Renderer.render(
        "account.password_reset",
        audience(user.id),
        %{
          first_name: first_word(user.person.display_name),
          title: "Reset your AutoQare password",
          url: "#{app}/reset-password?token=#{URI.encode(token)}"
        },
        chrome(org, "someone asked to reset the password of this account.", nil)
      )

    new()
    |> to(recipient(user.person.display_name, user.email))
    |> from(account_sender(org))
    |> put(rendered, "account.password_reset")
  end

  @doc """
  Confirming a new address. **Addressed to the new address, never to
  `user.email`**: the link proves the new mailbox, so it must arrive there.
  """
  @spec email_change(UserToken.t(), String.t()) :: Swoosh.Email.t()
  def email_change(%UserToken{user: user} = row, token) do
    org = Mail.organisation_of_user(user.id)
    app = app_url(user.id)

    rendered =
      Renderer.render(
        "account.email_change",
        audience(user.id),
        %{
          first_name: first_word(user.person.display_name),
          title: "Confirm your new email for AutoQare",
          url: "#{app}/account/confirm-email?token=#{URI.encode(token)}"
        },
        chrome(org, "someone asked to move an AutoQare account to this address.", nil)
      )

    new()
    |> to(recipient(user.person.display_name, UserToken.address(row)))
    |> from(account_sender(org))
    |> put(rendered, "account.email_change")
  end

  @doc "The notice to the **old** address that a change was asked (AQ-10B §5 A8)."
  @spec email_change_notice(UserToken.t(), String.t()) :: Swoosh.Email.t()
  def email_change_notice(%UserToken{user: user} = row, _token) do
    old_address_mail(
      user,
      "account.email_change_notice",
      "Your AutoQare email is changing",
      "Someone asked to move your account to #{UserToken.address(row)}."
    )
  end

  @doc "The notice to the **old** address that the change is done (AQ-10B §5 A9)."
  @spec email_changed(map(), String.t(), String.t()) :: Swoosh.Email.t()
  def email_changed(user, old_email, new_email) do
    user
    |> Map.put(:email, old_email)
    |> old_address_mail(
      "account.email_changed",
      "Your AutoQare email changed",
      "Your account now signs in with #{new_email}."
    )
  end

  defp old_address_mail(user, kind, title, body) do
    org = Mail.organisation_of_user(user.id)
    app = app_url(user.id)

    rendered =
      Renderer.render(
        kind,
        audience(user.id),
        %{
          first_name: first_word(user.person.display_name),
          title: title,
          body: body,
          url: "#{app}/account"
        },
        chrome(org, "this address signs in to an AutoQare account.", nil)
      )

    new()
    |> to(recipient(user.person.display_name, user.email))
    |> from(account_sender(org))
    |> put(rendered, kind)
  end

  # ── A notification ──────────────────────────────────────────────────────────

  @doc """
  A notification as mail (AQ-10B §7.1), its words the row's own:
  - the subject is the kind's (the title, on one line, at most 70);
  - the body: a greeting, the title, the row's body (a quote of a reply or
    a comment), the subject's facts, one button and the plain link into
    the right app (the console for staff, the portal for a customer),
    marking it read on arrival;
  - `ics`, a meeting's invite, rides as `invite.ics` (`text/calendar;
    method=REQUEST`, or `CANCEL` for a cancelled meeting).

  `recipient` is `Data.Notifications.recipient/1`'s: the account with its
  person, `customer?` and the settings.
  """
  @spec for_notification(map(), map(), String.t() | nil, DateTime.t()) :: Swoosh.Email.t()
  def for_notification(n, recipient, ics \\ nil, now \\ Utils.Clock.now()) do
    {email, _rendered} = notification_mail(n, recipient, ics, now)
    email
  end

  @doc "`for_notification/4` with what was rendered (`%{subject, html, text}`), for the gallery."
  @spec notification_mail(map(), map(), String.t() | nil, DateTime.t()) ::
          {Swoosh.Email.t(), map()}
  def notification_mail(%{} = n, recipient, ics, %DateTime{} = now) do
    kind = n.notification_kind
    group = kind.notification_group_key
    locked? = kind.is_locked
    customer? = recipient.customer?
    audience = if customer?, do: "customer", else: "staff"
    user = recipient.user
    app = if customer?, do: portal_url(), else: console_url()
    org = Mail.organisation(n.organisation_id) || %{name: "AutoQare"}
    token = unless locked?, do: Unsubscribe.sign(user.id, group, now)

    rendered =
      Renderer.render(
        n.notification_kind_key,
        audience,
        content(n, recipient, app),
        chrome(
          org,
          Why.line(n.notification_kind_key, customer?, recipient.settings.digest_frequency),
          app,
          %{
            token: token,
            group: group,
            locked?: locked?
          }
        )
      )

    email =
      new()
      |> to(recipient(user.person && user.person.display_name, user.email))
      |> from(if(locked?, do: account_sender(org), else: notification_sender(org)))
      |> reply_to_owner(customer?, n)
      |> list_unsubscribe(token)
      |> put(rendered, n.notification_kind_key)
      |> invite(ics)

    {email, rendered}
  end

  defp content(n, recipient, app) do
    base = %{
      first_name: first_name(recipient),
      title: n.title,
      body: n.body,
      url: app <> Notification.open_path(n),
      facts: facts(n, recipient.customer?)
    }

    case n.notification_kind_key do
      "account.digest" -> digest_content(base, n)
      _other -> base
    end
  end

  # The digest's body is its group lines, a blank line, then the titles.
  defp digest_content(base, n) do
    case String.split(n.body || "", "\n\n", parts: 2) do
      [heads, titles] ->
        %{base | body: heads, facts: []}
        |> Map.put(:items, String.split(titles, "\n", trim: true))
        |> Map.put(:url, String.replace(base.url, ~r/\?.*$/, "") <> "?unread=1")

      _one ->
        %{base | facts: []}
    end
  end

  defp facts(%{lead_id: lead_id, organisation_id: org} = _n, customer?) when is_binary(lead_id) do
    case Mail.lead(org, lead_id) do
      nil ->
        []

      lead ->
        [
          {"Role", lead.job.title},
          {"Company", lead.job.company && lead.job.company.name},
          {"Profile", unless(customer?, do: lead.profile.title)},
          {"Customer", unless(customer?, do: lead.profile.customer.display_name)},
          {"Stage", (lead.stage && lead.stage.name) || state_word(lead.state)}
        ]
    end
  end

  defp facts(%{task_id: task_id}, _customer?) when is_binary(task_id) do
    case Mail.task(task_id) do
      nil -> []
      task -> [{"Task", task.title}, {"Due", due(task.due_on, task.due_at)}]
    end
  end

  defp facts(%{approval_id: approval_id}, _customer?) when is_binary(approval_id) do
    case Mail.approval(approval_id) do
      nil -> []
      a -> [{"Approval", a.title}, {"Due", due(nil, a.due_at)}]
    end
  end

  defp facts(_n, _customer?), do: []

  defp state_word(:todo), do: "To do"
  defp state_word(:in_progress), do: "In progress"
  defp state_word(:on_hold), do: "On hold"
  defp state_word(:done), do: "Done"
  defp state_word(_other), do: nil

  defp due(%Date{} = on, _at), do: Calendar.strftime(on, "%a %-d %b")
  defp due(nil, %DateTime{} = at), do: Calendar.strftime(at, "%a %-d %b, %H:%M UTC")
  defp due(nil, nil), do: nil

  defp reply_to_owner(email, false, _n), do: email

  defp reply_to_owner(email, true, n) do
    customer_id =
      case Mail.customer_of_user(n.user_id) do
        nil -> nil
        customer -> customer.id
      end

    lead_id = n.lead_id || (n.approval_id && (Mail.approval(n.approval_id) || %{})[:lead_id])

    case Mail.reply_to(customer_id, lead_id) do
      nil -> email
      {name, address} -> reply_to(email, {name, address})
    end
  end

  defp list_unsubscribe(email, nil), do: email

  defp list_unsubscribe(email, token) do
    mailto = Application.get_env(:notifire, :unsubscribe_mailto, "unsubscribe@autoqare.com")

    email
    |> header(
      "List-Unsubscribe",
      "<#{api_url()}/unsubscribe?token=#{token}>, <mailto:#{mailto}?subject=unsubscribe>"
    )
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  # ── A customer with no portal login (QP10b-2) ───────────────────────────────

  @doc """
  A `customer_mail` row as mail (AQ-10B §11.4): the kind's customer
  template with `core`'s words, "Ask your team for a portal invitation to
  see everything", no link into the portal (they have none), `Reply-To`
  the profile's first owner, and a meeting's `invite.ics`. Answers the
  email and what was rendered.
  """
  @spec for_customer_mail(map(), map()) :: {Swoosh.Email.t(), map()}
  def for_customer_mail(row, customer) do
    org = Mail.organisation(row.organisation_id) || %{name: "AutoQare"}

    rendered =
      Renderer.render(
        row.kind_key,
        "customer",
        %{
          first_name: first_word(customer.display_name),
          title: row.subject,
          body: row.text,
          url: nil,
          no_login: true
        },
        chrome(org, "your team at #{org.name} is looking for work for you.", nil)
      )

    email =
      new()
      |> to(recipient(customer.display_name, row.to_email))
      |> from(notification_sender(org))
      |> then(fn email ->
        case Mail.reply_to(customer.id, nil) do
          nil -> email
          owner -> reply_to(email, owner)
        end
      end)
      |> put(rendered, row.kind_key)
      |> invite(row.ics)

    {email, rendered}
  end

  # ── The pieces ──────────────────────────────────────────────────────────────

  defp put(email, rendered, kind) do
    email
    |> subject(rendered.subject)
    |> html_body(rendered.html)
    |> text_body(rendered.text)
    |> header("X-AQ-Kind", kind)
  end

  defp chrome(org, why, app, opts \\ %{}) do
    org = org || %{name: "AutoQare"}

    unsubscribe =
      if app && opts[:token], do: "#{app}/unsubscribe?token=#{URI.encode_www_form(opts[:token])}"

    %{
      org_name: org.name,
      why: why,
      manage_url: app && "#{app}/notifications?sheet=settings",
      unsubscribe_url: unsubscribe,
      group_label: opts[:group] && Seed.group_label(opts[:group]),
      locked_note: if(opts[:locked?], do: @locked_note),
      help_email: Map.get(org, :help_email),
      postal_address: Map.get(org, :postal_address)
    }
  end

  defp invite(email, nil), do: email

  defp invite(email, ics) do
    method = if ics =~ "METHOD:CANCEL", do: "CANCEL", else: "REQUEST"

    attachment(
      email,
      Swoosh.Attachment.new({:data, ics},
        filename: "invite.ics",
        content_type: "text/calendar; method=#{method}",
        type: :attachment
      )
    )
  end

  defp first_name(%{customer?: true, user: user}) do
    case Mail.customer_of_user(user.id) do
      %{display_name: name} -> first_word(name)
      nil -> first_word(user.person && user.person.display_name)
    end
  end

  defp first_name(%{user: user}), do: first_word(user.person && user.person.display_name)

  defp first_word(nil), do: nil

  defp first_word(name) do
    case String.split(String.trim(name)) do
      [first | _rest] -> first
      [] -> nil
    end
  end

  defp audience(user_id) do
    if Mail.customer_of_user(user_id), do: "customer", else: "staff"
  end

  defp app_url(user_id) do
    if Mail.customer_of_user(user_id), do: portal_url(), else: console_url()
  end

  defp recipient(nil, email), do: email
  defp recipient(name, email), do: {name, email}

  defp notification_sender(org) do
    {"#{org.name} via AutoQare",
     Application.get_env(:notifire, :notifications_email, "notifications@autoqare.com")}
  end

  defp account_sender(org) do
    name = if org, do: "#{org.name} via AutoQare", else: "AutoQare"
    {name, Application.get_env(:notifire, :from_email, "hello@autoqare.com")}
  end

  defp accept_url(%Invitation{kind: kind, code: code}) do
    base = if kind == :customer, do: portal_url(), else: console_url()
    "#{base}/invite/#{code}"
  end

  defp console_url, do: Keyword.get(urls(), :console, "http://localhost:5800")
  defp portal_url, do: Keyword.get(urls(), :portal, "http://localhost:5801")
  defp urls, do: Application.get_env(:notifire, :app_urls, [])

  @doc "The backend's own origin, for `List-Unsubscribe` (`config :notifire, :api_url`)."
  @spec api_url() :: String.t()
  def api_url, do: Application.get_env(:notifire, :api_url, "http://localhost:4100")
end
