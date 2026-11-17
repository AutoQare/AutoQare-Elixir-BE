defmodule Data.Dashboards.Rows do
  @moduledoc """
  The rows the dashboards list (AQ-11 §3, §7.4), storage only: recent and
  *Apply again* applications, leads by state and quiet, meetings ahead,
  the customer's stage counts and replies. `subject` narrows whose, as in
  `Data.Dashboards`; who may see each row is `Core.Dashboards`' to decide.
  """

  import Ecto.Query, warn: false

  import Data.Dashboards, only: [narrow: 2, actor: 2]

  alias Data.Conversations.Message
  alias Data.Customers.{Customer, CustomerTeam, Profile, ProfileMember, Skill}
  alias Data.Leads.{Event, Lead}
  alias Data.Meetings.Meeting
  alias Data.Repo

  @doc """
  `applied` rows of `subject`, newest first: `window` narrows (nil: any
  time), `again: true` keeps the *Apply again* ones, `limit` caps.
  Each with its actor's person.
  """
  @spec applied_rows(map(), keyword()) :: [Event.t()]
  def applied_rows(subject, opts) do
    from(e in Event,
      as: :event,
      join: l in Lead,
      as: :lead,
      on: l.id == e.lead_id,
      join: j in assoc(l, :job),
      as: :job,
      where: e.organisation_id == ^subject.organisation_id and e.kind == :applied,
      order_by: [desc: e.occurred_at, desc: e.id],
      preload: [actor_user: :person]
    )
    |> narrow(subject)
    |> actor(subject[:actor_user_id])
    |> applied_window(opts[:window])
    |> then(&if(opts[:again], do: where(&1, [event: e], e.is_again), else: &1))
    |> then(&if(opts[:limit], do: limit(&1, ^opts[:limit]), else: &1))
    |> Repo.all()
  end

  defp applied_window(query, nil), do: query

  defp applied_window(query, {from, to}),
    do: where(query, [event: e], e.occurred_at >= ^from and e.occurred_at < ^to)

  @doc """
  Leads of `subject` with what every lead read carries: `states` (atoms),
  `live: true` (not archived), `quiet_before` (last activity at or before),
  `ids`.
  """
  @spec leads(map(), keyword()) :: [Lead.t()]
  def leads(subject, opts) do
    from(l in Lead,
      as: :lead,
      join: j in assoc(l, :job),
      as: :job,
      where: l.organisation_id == ^subject.organisation_id,
      order_by: [asc: l.last_activity_at, asc: l.id]
    )
    |> narrow(subject)
    |> then(&if(opts[:states], do: where(&1, [lead: l], l.state in ^opts[:states]), else: &1))
    |> then(&if(opts[:live], do: where(&1, [lead: l], is_nil(l.archived_at)), else: &1))
    |> then(&if(opts[:ids], do: where(&1, [lead: l], l.id in ^opts[:ids]), else: &1))
    |> quiet_before(opts[:quiet_before])
    |> Data.Leads.load_all()
  end

  defp quiet_before(query, nil), do: query

  defp quiet_before(query, %DateTime{} = at),
    do: where(query, [lead: l], l.last_activity_at <= ^at)

  @doc """
  Scheduled meetings of `subject`'s leads starting in `window`, soonest
  first, each as a meeting read carries it; `attendee_user_id` adds the
  meetings that person attends on any lead of the organisation.
  """
  @spec meetings(map(), {DateTime.t(), DateTime.t()}, keyword()) :: [Meeting.t()]
  def meetings(subject, {from, to}, opts \\ []) do
    leads =
      from(l in Lead, as: :lead, join: j in assoc(l, :job), as: :job, select: l.id)
      |> where([lead: l], l.organisation_id == ^subject.organisation_id)
      |> narrow(subject)

    whose =
      case opts[:attendee_user_id] do
        nil ->
          dynamic([m], m.lead_id in subquery(leads))

        user_id ->
          attended =
            from(a in Data.Meetings.Attendee, where: a.user_id == ^user_id, select: a.meeting_id)

          dynamic([m], m.lead_id in subquery(leads) or m.id in subquery(attended))
      end

    from(m in Meeting,
      where:
        m.organisation_id == ^subject.organisation_id and m.status == :scheduled and
          m.starts_at >= ^from and m.starts_at < ^to,
      where: ^whose,
      order_by: [asc: m.starts_at, asc: m.id],
      limit: 100,
      preload: ^Data.Meetings.preload()
    )
    |> Repo.all()
  end

  @doc """
  The leads of `subject` in progress or on hold, not archived, counted by
  their stage: `[%{profile_id, key, name, kind, anchor_kind, position,
  count}]` (the customer's Home).
  """
  @spec stage_counts(map()) :: [map()]
  def stage_counts(subject) do
    from(l in Lead,
      as: :lead,
      join: j in assoc(l, :job),
      as: :job,
      join: s in assoc(l, :stage),
      where:
        l.organisation_id == ^subject.organisation_id and is_nil(l.archived_at) and
          l.state in ^[:in_progress, :on_hold],
      group_by: [l.profile_id, s.key, s.name, s.kind, s.anchor_kind, s.position],
      select: %{
        profile_id: l.profile_id,
        key: s.key,
        name: s.name,
        kind: s.kind,
        anchor_kind: s.anchor_kind,
        position: s.position,
        count: count(l.id)
      }
    )
    |> narrow(subject)
    |> Repo.all()
  end

  @doc """
  The employers' replies on `subject`'s leads in the teams `team_ids`
  (inbound, not internal, not deleted, not the customer's own), newest
  first, at most `limit`: `[%{lead_id, team_id, job_title, company_name,
  sent_at, from_text, contact_name, body_text}]`.
  """
  @spec replies(map(), [binary()], pos_integer()) :: [map()]
  def replies(_subject, [], _limit), do: []

  def replies(subject, team_ids, limit) do
    from(e in Event,
      as: :event,
      join: l in Lead,
      as: :lead,
      on: l.id == e.lead_id,
      join: j in assoc(l, :job),
      as: :job,
      join: m in Message,
      on: m.id == e.message_id,
      left_join: c in assoc(m, :from_contact),
      left_join: co in assoc(j, :company),
      where:
        e.organisation_id == ^subject.organisation_id and e.kind == :message_in and
          j.team_id in ^team_ids and not m.is_internal and is_nil(m.deleted_at) and
          m.from_kind != :customer,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: ^limit,
      select: %{
        lead_id: e.lead_id,
        team_id: j.team_id,
        job_title: j.title,
        company_name: co.name,
        sent_at: e.occurred_at,
        from_text: m.from_text,
        contact_name: c.name,
        body_text: m.body_text
      }
    )
    |> narrow(subject)
    |> Repo.all()
  end

  @doc "How many employer replies `subject`'s leads in `team_ids` had in `window`."
  @spec reply_count(map(), [binary()], {DateTime.t(), DateTime.t()}) :: non_neg_integer()
  def reply_count(_subject, [], _window), do: 0

  def reply_count(subject, team_ids, {from, to}) do
    from(e in Event,
      as: :event,
      join: l in Lead,
      as: :lead,
      on: l.id == e.lead_id,
      join: j in assoc(l, :job),
      as: :job,
      join: m in Message,
      on: m.id == e.message_id,
      where:
        e.organisation_id == ^subject.organisation_id and e.kind == :message_in and
          j.team_id in ^team_ids and not m.is_internal and is_nil(m.deleted_at) and
          m.from_kind != :customer and e.occurred_at >= ^from and e.occurred_at < ^to
    )
    |> narrow(subject)
    |> Repo.aggregate(:count)
  end

  # ── Targets and names ───────────────────────────────────────────────────────

  @doc """
  The live profiles these people own (AQ-11 §5) — not archived, active, of
  a customer neither archived, paused nor ended — with each one's daily
  target and the teams serving its customer: `[%{user_id, profile_id,
  daily_target, team_ids}]`.
  """
  @spec owned_profiles([binary()]) :: [map()]
  def owned_profiles([]), do: []

  def owned_profiles(user_ids) do
    rows =
      from(pm in ProfileMember,
        join: p in Profile,
        on: p.id == pm.profile_id,
        join: c in Customer,
        on: c.id == p.customer_id,
        where:
          pm.user_id in ^user_ids and is_nil(p.archived_at) and p.status == :active and
            is_nil(c.archived_at) and c.status not in ^[:paused, :ended],
        select: %{
          user_id: pm.user_id,
          profile_id: p.id,
          daily_target: p.daily_target,
          customer_id: c.id
        }
      )
      |> Repo.all()

    teams =
      from(ct in CustomerTeam,
        where: ct.customer_id in ^Enum.map(rows, & &1.customer_id),
        select: {ct.customer_id, ct.team_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(rows, &Map.put(&1, :team_ids, Map.get(teams, &1.customer_id, [])))
  end

  @doc "Profiles by id with their customers: `%{id => profile}`."
  @spec profiles([binary()]) :: %{binary() => Profile.t()}
  def profiles(ids) do
    from(p in Profile, where: p.id in ^Enum.reject(ids, &is_nil/1), preload: [:customer])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Skills by id: `%{id => name}`."
  @spec skill_names([binary()]) :: %{binary() => String.t()}
  def skill_names(ids) do
    from(s in Skill, where: s.id in ^Enum.reject(ids, &is_nil/1), select: {s.id, s.name})
    |> Repo.all()
    |> Map.new()
  end
end
