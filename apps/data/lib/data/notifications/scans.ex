defmodule Data.Notifications.Scans do
  @moduledoc """
  What the notification scans read (AQ-10B §5, §11.4), every organisation's
  at once, storage only: the rules — who is told, when, in which words — are
  `Core.Notifications.Scans`'. Each read is bounded in time, so a first run
  on an old database doesn't tell of things long past.
  """

  import Ecto.Query, warn: false

  alias Data.Conversations.{Conversation, ConversationLead}
  alias Data.Customers.{Channel, Customer, ProfileChannel, ProfileMember}
  alias Data.Invitations.Invitation
  alias Data.Leads.Lead
  alias Data.Meetings.Meeting
  alias Data.Notifications.Delivery
  alias Data.Organisations.{OrgAdmin, Organisation}
  alias Data.Repo

  # ── Invitations ─────────────────────────────────────────────────────────────

  @doc "Open invitations (not accepted, not revoked) still live at `now`, with their organisation."
  @spec open_invitations(DateTime.t()) :: [Invitation.t()]
  def open_invitations(%DateTime{} = now) do
    from(i in Invitation,
      where: is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^usec(now),
      preload: [:organisation, :team, invited_by_user: :person]
    )
    |> Repo.all()
  end

  @doc "Invitations that expired unused between `since` and `now`."
  @spec expired_invitations(DateTime.t(), DateTime.t()) :: [Invitation.t()]
  def expired_invitations(%DateTime{} = since, %DateTime{} = now) do
    from(i in Invitation,
      where:
        is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at <= ^usec(now) and
          i.expires_at > ^usec(since)
    )
    |> Repo.all()
  end

  # ── Leads ───────────────────────────────────────────────────────────────────

  @doc "To do leads with an owner, live, last touched between `oldest` and `cutoff`."
  @spec untouched_leads(DateTime.t(), DateTime.t()) :: [Lead.t()]
  def untouched_leads(%DateTime{} = oldest, %DateTime{} = cutoff) do
    from(l in Lead,
      where:
        l.state == :todo and is_nil(l.archived_at) and not is_nil(l.owner_user_id) and
          coalesce(l.last_activity_at, l.inserted_at) <= ^usec(cutoff) and
          coalesce(l.last_activity_at, l.inserted_at) > ^usec(oldest)
    )
    |> Repo.all()
    |> Enum.map(&Data.Leads.reload/1)
  end

  # ── Conversations ───────────────────────────────────────────────────────────

  @doc "Triage items (no lead, not ignored) last moved between `oldest` and `cutoff`."
  @spec stale_triage(DateTime.t(), DateTime.t()) :: [Conversation.t()]
  def stale_triage(%DateTime{} = oldest, %DateTime{} = cutoff) do
    linked = from(l in ConversationLead, select: l.conversation_id)

    from(c in Conversation,
      where:
        is_nil(c.ignored_at) and c.id not in subquery(linked) and
          coalesce(c.last_message_at, c.inserted_at) <= ^usec(cutoff) and
          c.inserted_at > ^usec(oldest)
    )
    |> Repo.all()
  end

  @doc """
  Live email channels with a forwarding address whose latest landed mail
  came between `oldest` and `cutoff`: `[{channel, last_mail_at}]`, each
  channel with its customer.
  """
  @spec silent_channels(DateTime.t(), DateTime.t()) :: [{Channel.t(), DateTime.t()}]
  def silent_channels(%DateTime{} = oldest, %DateTime{} = cutoff) do
    last =
      from(m in Data.Inbound.InboundMessage,
        where: m.outcome == :landed and not is_nil(m.channel_id),
        group_by: m.channel_id,
        select: %{channel_id: m.channel_id, at: max(m.received_at)}
      )

    from(ch in Channel,
      join: l in subquery(last),
      on: l.channel_id == ch.id,
      where:
        ch.kind == :email and not is_nil(ch.inbound_token) and is_nil(ch.archived_at) and
          l.at <= ^usec(cutoff) and l.at > ^usec(oldest),
      preload: [:customer],
      select: {ch, l.at}
    )
    |> Repo.all()
  end

  @doc "The owners of the profiles a channel serves, else of the customer's profiles."
  @spec channel_owners(Channel.t()) :: [binary()]
  def channel_owners(%Channel{} = channel) do
    linked =
      from(m in ProfileMember,
        join: pc in ProfileChannel,
        on: pc.profile_id == m.profile_id,
        where: pc.channel_id == ^channel.id,
        select: m.user_id
      )
      |> Repo.all()

    if linked != [] do
      Enum.uniq(linked)
    else
      from(m in ProfileMember,
        join: p in assoc(m, :profile),
        where: p.customer_id == ^channel.customer_id and is_nil(p.archived_at),
        distinct: true,
        select: m.user_id
      )
      |> Repo.all()
    end
  end

  # ── Meetings ────────────────────────────────────────────────────────────────

  @doc "Proposed meetings starting between `now` and `until`, read as a notice reads them."
  @spec unconfirmed_meetings(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def unconfirmed_meetings(%DateTime{} = now, %DateTime{} = until) do
    from(m in Meeting,
      where: m.status == :proposed and m.starts_at > ^usec(now) and m.starts_at <= ^usec(until),
      select: m.id
    )
    |> Repo.all()
    |> Enum.map(&Data.Meetings.get_for_system/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Scheduled meetings (no outcome logged) that ended between `oldest` and `cutoff`."
  @spec meetings_without_outcome(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def meetings_without_outcome(%DateTime{} = oldest, %DateTime{} = cutoff) do
    from(m in Meeting,
      where: m.status == :scheduled and m.ends_at <= ^usec(cutoff) and m.ends_at > ^usec(oldest),
      select: m.id
    )
    |> Repo.all()
    |> Enum.map(&Data.Meetings.get_for_system/1)
    |> Enum.reject(&is_nil/1)
  end

  # ── The week (QP10b-13) ─────────────────────────────────────────────────────

  # The week's numbers are the dashboards' (AQ-11 QP11-12): `Data.Dashboards`.

  @doc "Customers with no portal login and an address, for the weekly report by mail."
  @spec customers_without_login() :: [Customer.t()]
  def customers_without_login do
    from(c in Customer,
      where:
        is_nil(c.user_id) and not is_nil(c.email) and is_nil(c.archived_at) and
          c.status in [:invited, :active]
    )
    |> Repo.all()
  end

  # ── The system admin's checks ───────────────────────────────────────────────

  @doc "Every organisation with its one system admin's user id: `[{organisation_id, user_id}]`."
  @spec admins() :: [{binary(), binary()}]
  def admins do
    from(a in OrgAdmin,
      join: o in Organisation,
      on: o.id == a.organisation_id,
      select: {a.organisation_id, a.user_id}
    )
    |> Repo.all()
  end

  @doc "Failed deliveries per organisation updated since `since`: `%{organisation_id => n}`."
  @spec delivery_failures(DateTime.t()) :: %{binary() => non_neg_integer()}
  def delivery_failures(%DateTime{} = since) do
    from(d in Delivery,
      where: d.updated_at >= ^usec(since) and (d.state == :failed or not is_nil(d.error)),
      group_by: d.organisation_id,
      select: {d.organisation_id, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Forwarded mail the intake couldn't read or refused for size, since `since`."
  @spec inbound_failures(DateTime.t()) :: non_neg_integer()
  def inbound_failures(%DateTime{} = since) do
    from(m in Data.Inbound.InboundMessage,
      where: m.received_at >= ^usec(since) and m.outcome in [:unreadable, :too_large]
    )
    |> Repo.aggregate(:count)
  end

  @doc "Background jobs Oban discarded since `since`: `[worker]`."
  @spec discarded_jobs(DateTime.t()) :: [String.t()]
  def discarded_jobs(%DateTime{} = since) do
    from(j in "oban_jobs",
      where: j.state == "discarded" and j.discarded_at >= ^DateTime.to_naive(since),
      select: j.worker
    )
    |> Repo.all()
  end

  @doc "Selector misses per organisation and site on `day`: `[{organisation_id, site, count}]`."
  @spec misses_on(Date.t()) :: [{binary(), atom(), non_neg_integer()}]
  def misses_on(%Date{} = day) do
    from(m in "extension_misses",
      where: m.seen_on == ^day,
      group_by: [m.organisation_id, m.site],
      select: {type(m.organisation_id, :binary_id), m.site, sum(m.count)}
    )
    |> Repo.all()
    |> Enum.map(fn {org, site, n} ->
      {org, String.to_existing_atom(site), Decimal.to_integer(n)}
    end)
  end

  defp usec(%DateTime{microsecond: {us, _p}} = at), do: %{at | microsecond: {us, 6}}
end
