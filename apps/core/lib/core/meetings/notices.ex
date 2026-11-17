defmodule Core.Meetings.Notices do
  @moduledoc """
  Who is told about a meeting (AQ-06 §8.3, §11.6), each row ensured by its
  dedupe key and worded in the recipient's zone; the seam plans its
  deliveries (AQ-08 §7.1). **A customer without a portal account has no
  bell**: since P10b they are mailed the scheduled, changed and tomorrow
  notices with the `.ics` (`Core.Notifications.CustomerMail`, QP10b-2).

  | Kind | Who | Dedupe |
  |---|---|---|
  | `meetings.scheduled` · `meetings.changed` | the customer, the lead's owner, staff attendees — not the actor | `meeting:<id>:<sequence>` |
  | `meetings.day_before` | the 24 h reminder (AQ-08 QP8-4: with email), to the same people | `meeting:<id>:remind:1440:<starts_at>` |
  | `meetings.reminder` | the 1 h and 10 min reminders, to the same people; passes quiet hours | `meeting:<id>:remind:<offset>:<starts_at>` |
  | `meetings.proposed` | an invitation's proposal (AQ-09 §11.4), to the lead's owner alone | `meeting:<id>:proposed:<sequence>` (the invitation's) |
  | `meetings.clash` | a meeting saved over another of the customer's: the owner and staff attendees, not the actor (AQ-10B §5.5 M7) | `meeting:<id>:clash:<sequence>` |
  | `meetings.unconfirmed` · `meetings.log_outcome` | the scans' (`Core.Notifications.Scans`) | — |

  `scheduled` and `changed` pass quiet hours when the meeting is within 24
  hours (AQ-10B §5.5 M1).

  **The emails of `scheduled` and `changed` carry the invite** (AQ-08
  §11.4): the meeting's `.ics` from `Core.Meetings.Ics`, `METHOD:REQUEST`,
  or `CANCEL` for a cancelled one, rendered here and handed to the seam as
  bytes (`ics:`), so `notifire` attaches it without reading a meeting.

  The customer reads staff by first name only when the lead's team shows
  names, else "The team".
  """

  alias Core.Meetings.{Ics, Sheet, Words}
  alias Core.Notifications
  alias Core.Notifications.CustomerMail
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Scope
  alias Data.Teams

  @doc "`meetings.scheduled`: \"Fiza scheduled Technical interview with Corvid Security · Wed 18 Nov 14:00 PKT\"."
  @spec scheduled(Scope.t(), map()) :: list()
  def scheduled(scope, meeting) do
    tell_all(
      scope,
      meeting,
      "meetings.scheduled",
      "meeting:#{meeting.id}:#{meeting.sequence}",
      fn who, zone ->
        "#{who} scheduled #{about(meeting)} · #{Words.at(meeting.starts_at, zone)}"
      end
    )
  end

  @doc "`meetings.changed`: moved, or cancelled."
  @spec changed(Scope.t(), map()) :: list()
  def changed(scope, meeting) do
    tell_all(
      scope,
      meeting,
      "meetings.changed",
      "meeting:#{meeting.id}:#{meeting.sequence}",
      fn _who, zone ->
        if meeting.status == :cancelled,
          do: "#{about(meeting)} was cancelled",
          else: "#{about(meeting)} moved to #{Words.at(meeting.starts_at, zone)}"
      end
    )
  end

  @doc """
  `meetings.clash` (AQ-10B §5.5 M7) when a meeting is saved over another
  of the customer's (`Core.Meetings.Sheet.clash_for/5` decides, and words
  it): the owner and staff attendees, never the actor.
  """
  @spec clash(Scope.t(), map(), map()) :: list()
  def clash(scope, lead, meeting) do
    case Sheet.clash_for(
           scope,
           lead,
           meeting.starts_at,
           meeting.ends_at,
           meeting.id
         ) do
      %{words: words} -> clash_told(scope, meeting, words)
      nil -> []
    end
  end

  defp clash_told(scope, meeting, words) do
    for {user_id, _zone, false} <- recipients(meeting), user_id != Scope.user_id(scope) do
      ensure(
        scope,
        meeting,
        user_id,
        "meetings.clash",
        "meeting:#{meeting.id}:clash:#{meeting.sequence}",
        title: "#{about(meeting)} clashes: #{words}",
        actor: nil,
        link: link(meeting, user_id)
      )
    end
  end

  @doc """
  `meetings.proposed` (AQ-09 §12.3) to the lead's owner, in their zone:
  "Corvid Security sent an invitation: Technical interview, Wed 18 Nov
  14:00 PKT. Confirm it?" — for a proposed move "Corvid Security moved
  Technical interview to Thu 19 Nov 15:00 PKT. Accept the change?", for a
  cancel "Corvid Security cancelled Technical interview. Accept the
  cancel?". The sender is the job's company, else the organizer.
  """
  @spec proposed(Scope.t(), map()) :: list()
  def proposed(scope, meeting) do
    owner = meeting.lead.owner_user_id
    proposal = meeting.proposal || %{}

    if is_nil(owner) or owner == Scope.user_id(scope) do
      []
    else
      zone = zone_of(owner)
      who = sender(meeting, proposal)

      title =
        case proposal["change"] do
          %{"cancel" => true} ->
            "#{who} cancelled #{meeting.title}. Accept the cancel?"

          %{"starts_at" => at} when is_binary(at) ->
            {:ok, starts, _offset} = DateTime.from_iso8601(at)
            "#{who} moved #{meeting.title} to #{Words.at(starts, zone)}. Accept the change?"

          _new ->
            "#{who} sent an invitation: #{meeting.title}, #{Words.at(meeting.starts_at, zone)}. Confirm it?"
        end

      ensure(
        scope,
        meeting,
        owner,
        "meetings.proposed",
        "meeting:#{meeting.id}:proposed:#{proposal["sequence"] || 0}",
        title: title,
        actor: nil,
        link: "/leads/#{meeting.lead_id}"
      )
    end
  end

  defp sender(meeting, proposal) do
    case meeting.lead.job.company do
      %{name: name} -> name
      _none -> proposal["organizer"] || "Someone"
    end
  end

  # The invite an email carries (AQ-08 §11.4).
  defp invite(%{status: :cancelled} = meeting), do: Ics.for_meeting(meeting, "CANCEL")
  defp invite(meeting), do: Ics.for_meeting(meeting, "REQUEST")

  @doc """
  The reminder at `offset` minutes before, to everyone it concerns (the
  actor too: nobody acts on a reminder): "Technical interview with Corvid
  Security in 1 hour · 14:00 PKT · Google Meet". The 24 h one is
  `meetings.day_before` (AQ-08 QP8-4), the others `meetings.reminder`.
  """
  @spec reminder(Scope.t(), map(), pos_integer()) :: list()
  def reminder(scope, meeting, offset) do
    dedupe = "meeting:#{meeting.id}:remind:#{offset}:#{DateTime.to_iso8601(meeting.starts_at)}"
    kind = if offset == 1440, do: "meetings.day_before", else: "meetings.reminder"

    told =
      for {user_id, zone, _customer?} <- recipients(meeting) do
        ensure(scope, meeting, user_id, kind, dedupe,
          title: reminder_words(meeting, offset, zone),
          actor: nil,
          link: link(meeting, user_id)
        )
      end

    if offset == 1440,
      do:
        mail_customer(meeting, "meetings.day_before", dedupe, fn zone ->
          reminder_words(meeting, offset, zone)
        end)

    told
  end

  defp reminder_words(meeting, offset, zone) do
    "#{about(meeting)} #{Words.before(offset)} · #{Words.clock(meeting.starts_at, zone)} " <>
      "#{abbr(meeting.starts_at, zone)} · #{Words.platform(meeting.platform)}"
  end

  # AQ-10B QP10b-2: a customer with no login is mailed, with the `.ics`.
  defp mail_customer(meeting, kind, dedupe, words) do
    customer = meeting.lead.profile.customer

    lines =
      [
        "When: #{Words.at(meeting.starts_at, customer.timezone)}",
        "Where: #{Words.platform(meeting.platform)}",
        meeting.join_url && "Join: #{meeting.join_url}",
        meeting.address && "Address: #{meeting.address}"
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    _written =
      CustomerMail.write(
        customer,
        %{
          kind: kind,
          subject: words.(customer.timezone),
          text: Enum.join(lines, "\n"),
          dedupe: "mail:" <> dedupe,
          ics:
            if(kind == "meetings.day_before",
              do: Ics.for_meeting(meeting, "REQUEST"),
              else: invite(meeting)
            )
        },
        Core.Clock.now()
      )

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp tell_all(scope, meeting, kind, dedupe, words) do
    actor = Scope.user_id(scope) && Accounts.get_user(Scope.user_id(scope))
    names? = Teams.get_settings(meeting.lead.job.team_id).customer_sees_staff_names

    ics = invite(meeting)
    soon? = DateTime.diff(meeting.starts_at, Core.Clock.now(), :second) < 86_400

    told =
      for {user_id, zone, customer?} <- recipients(meeting), user_id != Scope.user_id(scope) do
        who = who(actor, customer?, names?)

        ensure(scope, meeting, user_id, kind, dedupe,
          title: words.(who, zone),
          actor: if(customer? and not names?, do: nil, else: actor),
          link: link(meeting, user_id),
          ics: ics,
          passes: if(soon?, do: true)
        )
      end

    mail_customer(meeting, kind, dedupe, &words.(who(nil, true, names?), &1))
    told
  end

  defp who(nil, _customer?, _names?), do: "The team"
  defp who(actor, true, true), do: Person.first_name(actor) || "The team"
  defp who(_actor, true, false), do: "The team"
  defp who(actor, false, _names?), do: Person.first_name(actor) || "Someone"

  @doc false
  # `{user_id, zone, customer?}`: the customer (with a login), the owner,
  # the staff attendees, once each.
  def recipients(meeting) do
    lead = meeting.lead
    customer = lead.profile.customer

    staff =
      [lead.owner_user_id | for(a <- meeting.attendees, a.user_id, do: a.user_id)]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == customer.user_id))
      |> Enum.map(fn id -> {id, zone_of(id), false} end)

    customer_row =
      if customer.user_id, do: [{customer.user_id, customer.timezone, true}], else: []

    customer_row ++ staff
  end

  defp zone_of(user_id) do
    case Accounts.get_user(user_id) do
      %{person: %{timezone: zone}} -> zone
      _other -> "Etc/UTC"
    end
  end

  defp link(meeting, user_id) do
    if user_id == meeting.lead.profile.customer.user_id,
      do: "/meetings",
      else: "/leads/#{meeting.lead_id}"
  end

  defp about(meeting) do
    case meeting.lead.job.company do
      %{name: name} -> "#{meeting.title} with #{name}"
      _none -> meeting.title
    end
  end

  defp abbr(at, zone) do
    case DateTime.shift_zone(at, zone || "Etc/UTC") do
      {:ok, %{zone_abbr: abbr}} -> abbr
      _unknown -> "UTC"
    end
  end

  defp ensure(scope, meeting, user_id, kind, dedupe, opts) do
    {:ok, row} =
      Notifications.ensure(scope, %{
        organisation_id: meeting.organisation_id,
        user_id: user_id,
        notification_kind_key: kind,
        actor_user_id: opts[:actor] && opts[:actor].id,
        lead_id: meeting.lead_id,
        title: opts[:title],
        link_path: opts[:link],
        dedupe_key: dedupe,
        ics: opts[:ics],
        passes_quiet_hours: opts[:passes]
      })

    if row.is_new,
      do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
