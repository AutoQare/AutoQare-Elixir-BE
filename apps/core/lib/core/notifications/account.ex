defmodule Core.Notifications.Account do
  @moduledoc """
  Who is told about accounts, teams and the extension (AQ-10B §5.1, §5.7,
  §11.4), each row through the seam (`Core.Notifications.ensure/3`) and
  ensured by its dedupe key. Inside the verb's transaction, like every
  notice.

  | Kind | Who | Dedupe |
  |---|---|---|
  | `account.invitation_accepted` | the inviter; for a customer also the team leads and profile owners | `invitation:<id>:accepted` |
  | `account.invitation_expired` | the inviter | `invitation:<id>:expired` |
  | `account.welcome` | the person, at their first sign-in | `welcome:<user>` |
  | `account.security` 🔒 | the person: password changed, email changed, signed out everywhere, suspended, restored, system admin handed on (and the old admin) | `security:<user>:<what>:<at>` |
  | `account.team_changed` | the person added to or removed from a team, or whose role changed | `team:<id>:member:<user>:<what>:<at>` |
  | `account.extension_connected` 🔒 | the person a device connected for | `device:<id>:connected` |
  | `account.extension_off` | the person whose device someone else disconnected | `device:<id>:off` |

  **Never the actor** — except the security kinds, which are about the
  person's own account and go to them whoever acted (a changed password
  is the person's own act, and "if this wasn't you" is the point).
  """

  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Scope
  alias Data.Teams

  # ── Invitations ─────────────────────────────────────────────────────────────

  @doc """
  `account.invitation_accepted`: "Hira accepted your invitation to Backend
  squad." to the inviter; for a customer "Tanweer joined the portal." to
  the inviter, the leads of the customer's teams and the profile owners.
  """
  @spec invitation_accepted(map(), map(), DateTime.t()) :: list()
  def invitation_accepted(invitation, user, %DateTime{} = now) do
    name = display_name(user) || invitation.invited_name || invitation.email
    {title, link, people} = accepted_words(invitation, name)

    [invitation.invited_by_user_id | people]
    |> Enum.uniq()
    |> Enum.reject(&(is_nil(&1) or &1 == user.id))
    |> Enum.map(
      &tell(invitation.organisation_id, &1, "account.invitation_accepted", now,
        title: title,
        link: link,
        dedupe: "invitation:#{invitation.id}:accepted"
      )
    )
  end

  # `{title, link, who else is told}` per kind of invitation.
  defp accepted_words(%{kind: :customer, customer_id: id} = invitation, name)
       when is_binary(id) do
    case Data.Customers.get(invitation.organisation_id, id) do
      nil -> {"#{name} joined the portal", "/customers", []}
      c -> {"#{c.display_name} joined the portal", "/customers/#{c.id}", customer_people(c)}
    end
  end

  defp accepted_words(%{kind: :team_member, team: %{name: team}}, name),
    do: {"#{name} accepted your invitation to #{team}", "/settings/people", []}

  defp accepted_words(_admin_or_unknown, name),
    do: {"#{name} accepted your invitation", "/settings/people", []}

  @doc "`account.invitation_expired`: \"Your invitation to hira@example.com expired unused.\""
  @spec invitation_expired(map(), DateTime.t()) :: list()
  def invitation_expired(invitation, %DateTime{} = now) do
    case invitation.invited_by_user_id do
      nil ->
        []

      inviter ->
        tell(invitation.organisation_id, inviter, "account.invitation_expired", now,
          title: "Your invitation to #{invitation.email} expired unused",
          body: "Send a new one from Settings when they're ready.",
          link: "/settings/invitations",
          dedupe: "invitation:#{invitation.id}:expired"
        )
    end
  end

  defp customer_people(customer) do
    leads =
      for team_id <- customer.team_ids,
          m <- Teams.list_members(team_id),
          m.role == :lead,
          do: m.user_id

    owners = for p <- customer.profiles, m <- p.profile_members, do: m.user_id
    leads ++ owners
  end

  # ── Welcome ─────────────────────────────────────────────────────────────────

  @doc """
  `account.welcome` at the person's first sign-in: staff are told to
  connect the extension and turn on push; a customer what to expect and to
  add the portal to their Home Screen. Once per person.
  """
  @spec welcome(map(), binary() | nil, boolean(), DateTime.t()) :: list()
  def welcome(_user, nil, _customer?, _now), do: []

  def welcome(user, organisation_id, customer?, %DateTime{} = now) do
    body =
      if customer?,
        do:
          "Your team shares your applications, tasks and meetings here. " <>
            "Add the portal to your Home Screen to get push on your phone.",
        else: "Connect the Chrome extension and turn on push, so replies and meetings reach you."

    tell(organisation_id, user.id, "account.welcome", now,
      title: "Welcome to AutoQare",
      body: body,
      link: "/",
      dedupe: "welcome:#{user.id}"
    )
  end

  # ── Security (locked) ───────────────────────────────────────────────────────

  @doc """
  `account.security` for `what`: `:password_changed`, `{:email_changed,
  new}`, `:signed_out_everywhere`, `:suspended`, `:restored`,
  `{:admin_to, name}` (you're now the system admin) or `{:admin_from,
  name}` (you handed it on). Locked: always sent, at once.
  """
  @spec security(map(), binary() | nil, term(), DateTime.t()) :: list()
  def security(_user, nil, _what, _now), do: []

  def security(user, organisation_id, what, %DateTime{} = now) do
    {key, title, body} = security_words(what)

    tell(organisation_id, user.id, "account.security", now,
      title: title,
      body: body,
      link: "/account",
      dedupe: "security:#{user.id}:#{key}:#{DateTime.to_unix(now, :microsecond)}"
    )
  end

  defp security_words(:password_changed),
    do:
      {"password", "Your password was changed",
       "If this wasn't you, reset it now and tell your team."}

  defp security_words({:email_changed, new}),
    do:
      {"email", "Your sign-in email is now #{new}",
       "Your old address no longer signs in. If this wasn't you, tell your team now."}

  defp security_words(:signed_out_everywhere),
    do:
      {"sessions", "You were signed out on every device",
       "Sign in again where you need AutoQare."}

  defp security_words(:suspended),
    do: {"suspended", "Your account was suspended", "You can't sign in until it's restored."}

  defp security_words(:restored),
    do: {"restored", "Your account was restored", "You can sign in again."}

  defp security_words({:admin_to, from}),
    do: {"admin_to", "You're now the system admin", "#{from} handed the role to you."}

  defp security_words({:admin_from, to}),
    do: {"admin_from", "#{to} is now the system admin", "You're no longer the system admin."}

  # ── Teams ───────────────────────────────────────────────────────────────────

  @doc """
  `account.team_changed` to the person (never the actor): `:added`,
  `:removed` or `{:role, role}`. "Fiza added you to Backend squad.",
  "Fiza made you a team lead of Backend squad."
  """
  @spec team_changed(Scope.t(), map(), binary(), term(), DateTime.t()) :: list()
  def team_changed(%Scope{} = scope, team, user_id, what, %DateTime{} = now) do
    if user_id == Scope.user_id(scope) do
      []
    else
      who = actor_name(scope)

      {key, title} =
        case what do
          :added -> {"added", "#{who} added you to #{team.name}"}
          :removed -> {"removed", "#{who} removed you from #{team.name}"}
          {:role, :lead} -> {"lead", "#{who} made you a team lead of #{team.name}"}
          {:role, _member} -> {"member", "#{who} made you staff in #{team.name}"}
        end

      tell(team.organisation_id, user_id, "account.team_changed", now,
        title: title,
        actor: Scope.user_id(scope),
        link: if(what == :removed, do: "/", else: "/board?team=#{team.id}"),
        dedupe: "team:#{team.id}:member:#{user_id}:#{key}:#{DateTime.to_unix(now, :microsecond)}"
      )
    end
  end

  # ── The extension ───────────────────────────────────────────────────────────

  @doc "`account.extension_connected` (locked) to the device's person: \"The extension connected: Chrome on macOS\"."
  @spec extension_connected(map(), binary() | nil, DateTime.t()) :: list()
  def extension_connected(_device, nil, _now), do: []

  def extension_connected(device, organisation_id, %DateTime{} = now) do
    tell(organisation_id, device.user_id, "account.extension_connected", now,
      title: "The extension connected to your account",
      body: device_words(device),
      link: "/settings/extension",
      dedupe: "device:#{device.id}:connected"
    )
  end

  @doc "`account.extension_off` to the device's person, when someone else disconnected it."
  @spec extension_off(Scope.t(), map(), DateTime.t()) :: list()
  def extension_off(%Scope{} = scope, device, %DateTime{} = now) do
    if device.user_id == Scope.user_id(scope) do
      []
    else
      tell(Scope.organisation_id(scope), device.user_id, "account.extension_off", now,
        title: "#{actor_name(scope)} disconnected your extension",
        body: device_words(device),
        actor: Scope.user_id(scope),
        link: "/settings/extension",
        dedupe: "device:#{device.id}:off"
      )
    end
  end

  defp device_words(device) do
    case Map.get(device, :label) || Map.get(device, :name) do
      nil -> nil
      label -> to_string(label)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp actor_name(scope) do
    case Scope.user_id(scope) && Accounts.get_user(Scope.user_id(scope)) do
      %{} = user -> Person.first_name(user) || "Someone"
      _system -> "The system admin"
    end
  end

  defp display_name(%{id: id}) do
    case Accounts.get_user(id) do
      %{person: %{display_name: name}} -> name
      _none -> nil
    end
  end

  defp tell(nil, _user_id, _kind, _now, _opts), do: []

  defp tell(organisation_id, user_id, kind, now, opts) do
    {:ok, row} =
      Notifications.ensure(
        Scope.system(%{id: organisation_id}),
        %{
          organisation_id: organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          actor_user_id: opts[:actor],
          title: opts[:title],
          body: opts[:body],
          link_path: opts[:link],
          dedupe_key: opts[:dedupe]
        },
        now
      )

    if row.is_new,
      do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
