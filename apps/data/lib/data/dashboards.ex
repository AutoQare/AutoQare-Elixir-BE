defmodule Data.Dashboards do
  @moduledoc """
  What the dashboards count (AQ-11 §4, §7.4), storage only: the windows,
  the kinds that make a response or an interview, who counts and the words
  are `Core.Dashboards`'. **One query for a set of windows**, a
  `filter(count(…))` per window (tCart's pattern); a window is `{from,
  to}`, instants in UTC, `to` exclusive, built by the caller from dates.

  `subject` narrows whose: `organisation_id` (always), `team_ids` (nil:
  every team), `actor_user_id` (who applied), `owner_user_id` (the lead's
  owner), `customer_id`, `profile_ids`. `rules` names the kinds:
  `response_kinds`, `interview_kinds`, `offer_kinds` (engine stage kinds),
  `answer_outcomes` (an outcome that is an answer), `interview_meetings`
  and `meeting_statuses` (a meeting that counts as an interview).

  An application is an `applied` row (an *Apply again* too). It **has had a
  response** when the lead's latest response — an employer's `message_in`
  (not the customer's, not deleted), an `applied` or `stage_moved` that
  reached a response kind, an `outcome_set` with an answer outcome — is at
  or after it; the funnel's steps read the same way.
  """

  import Ecto.Query, warn: false

  alias Data.Conversations.{Conversation, ConversationLead, Message}
  alias Data.Customers.{Profile, ProfileChannel, ProfileMember}
  alias Data.Jobs.JobSkill
  alias Data.Leads.{Event, Fingerprint, Lead}
  alias Data.Meetings.Meeting
  alias Data.Repo

  @reach_kinds [:message_in, :applied, :stage_moved, :outcome_set]
  @stage_events [:applied, :stage_moved]

  # ── Applications and responses ──────────────────────────────────────────────

  @doc """
  Applications in each window and how many have had a response:
  `%{key => %{count, responses}}`; with `group` (`:profile`, `:platform`,
  `:skill`, `:actor`) a row per group, `[%{group, key => %{count,
  responses}}]` (a lead counts under each of its job's skills).
  """
  @spec applications(map(), map(), map(), atom() | nil) :: map() | [map()]
  def applications(subject, windows, rules, group \\ nil) do
    {low, high} = bounds(windows)

    selects =
      Enum.reduce(windows, %{}, fn {key, {from, to}}, acc ->
        inside = dynamic([event: e], e.occurred_at >= ^from and e.occurred_at < ^to)

        acc
        |> Map.put("#{key}.count", dynamic([event: e], filter(count(e.id), ^inside)))
        |> Map.put(
          "#{key}.responses",
          dynamic(
            [event: e, reached: r],
            filter(count(e.id), ^inside and r.responded_at >= e.occurred_at)
          )
        )
      end)

    from(e in Event,
      as: :event,
      join: l in Lead,
      as: :lead,
      on: l.id == e.lead_id,
      join: j in assoc(l, :job),
      as: :job,
      left_join: r in subquery(reached(subject.organisation_id, rules)),
      as: :reached,
      on: r.lead_id == e.lead_id,
      where:
        e.organisation_id == ^subject.organisation_id and e.kind == :applied and
          e.occurred_at >= ^low and e.occurred_at < ^high
    )
    |> narrow(subject)
    |> actor(subject[:actor_user_id])
    |> grouped(group, selects, windows)
  end

  @doc """
  Per lead of the organisation, the latest moment of each kind of progress
  — `%{lead_id, responded_at, interview_at, offer_at, hired_at}` — as a
  query: what makes an application *have had a response* here, and the
  Tracker's `had_response` filter (`Data.Filters.Leads`) too, so a tile and
  the list it opens read one rule.
  """
  @spec reached(binary(), map()) :: Ecto.Query.t()
  def reached(organisation_id, rules) do
    latest = &dynamic([reach: r], filter(max(r.occurred_at), ^&1))

    from(r in Event,
      as: :reach,
      left_join: m in Message,
      as: :message,
      on: m.id == r.message_id,
      where: r.organisation_id == ^organisation_id and r.kind in ^@reach_kinds,
      group_by: r.lead_id,
      select:
        ^%{
          lead_id: dynamic([reach: r], r.lead_id),
          responded_at: latest.(responded(rules)),
          interview_at: latest.(reached_kind(rules.interview_kinds)),
          offer_at: latest.(reached_kind(rules.offer_kinds)),
          hired_at: latest.(dynamic([reach: r], r.kind == :outcome_set and r.outcome == :hired))
        }
    )
  end

  # An employer's reply, a stage past the waiting ones, or an answer outcome.
  defp responded(rules) do
    reply =
      dynamic(
        [reach: r, message: m],
        r.kind == :message_in and
          (is_nil(m.id) or (m.from_kind != :customer and is_nil(m.deleted_at)))
      )

    answer =
      dynamic([reach: r], r.kind == :outcome_set and r.outcome in ^rules.answer_outcomes)

    dynamic(^reply or ^reached_kind(rules.response_kinds) or ^answer)
  end

  defp reached_kind(kinds),
    do: dynamic([reach: r], r.kind in ^@stage_events and r.stage_kind in ^kinds)

  @doc false
  # Applications by one person.
  def actor(query, nil), do: query
  def actor(query, user_id), do: where(query, [event: e], e.actor_user_id == ^user_id)

  # ── Interviews ──────────────────────────────────────────────────────────────

  @doc """
  Leads with an interview in each window — a meeting of an interview kind
  starting in it (not proposed or cancelled), or an `applied` /
  `stage_moved` reaching an interview kind in it — each lead once:
  `%{key => n}`; with `group: :owner`, `[%{group, key => n}]`.
  """
  @spec interviews(map(), map(), map(), atom() | nil) :: map() | [map()]
  def interviews(subject, windows, rules, group \\ nil) do
    {low, high} = bounds(windows)

    selects =
      Map.new(windows, fn {key, {from, to}} ->
        {"#{key}",
         dynamic(
           [moment: t, lead: l],
           filter(count(l.id, :distinct), t.at >= ^from and t.at < ^to)
         )}
      end)

    from(t in subquery(interview_moments(subject.organisation_id, rules, low, high)),
      as: :moment,
      join: l in Lead,
      as: :lead,
      on: l.id == t.lead_id,
      join: j in assoc(l, :job),
      as: :job
    )
    |> narrow(subject)
    |> grouped(group, selects, windows)
  end

  @doc """
  The leads with an interview in `{from, to}` by exactly the rule
  `interviews/4` counts — a meeting of an interview kind starting in it
  with a counting status, or an `applied` / `stage_moved` reaching an
  interview kind in it: a query of `lead_id`s, for the Tracker's
  `interviewed_on` (`Data.Filters.Leads`), so the *Interviews* tile and
  the list it opens agree.
  """
  @spec interviewed_leads(binary(), map(), {DateTime.t(), DateTime.t()}) :: Ecto.Query.t()
  def interviewed_leads(organisation_id, rules, {from, to}) do
    from(t in subquery(interview_moments(organisation_id, rules, from, to)),
      where: not is_nil(t.lead_id),
      select: t.lead_id
    )
  end

  defp interview_moments(organisation_id, rules, low, high) do
    stages =
      from(e in Event,
        where:
          e.organisation_id == ^organisation_id and e.kind in ^@stage_events and
            e.stage_kind in ^rules.interview_kinds and e.occurred_at >= ^low and
            e.occurred_at < ^high,
        select: %{lead_id: e.lead_id, at: e.occurred_at}
      )

    from(m in Meeting,
      where:
        m.organisation_id == ^organisation_id and m.meeting_kind in ^rules.interview_meetings and
          m.status in ^rules.meeting_statuses and m.starts_at >= ^low and m.starts_at < ^high,
      select: %{lead_id: m.lead_id, at: m.starts_at},
      union_all: ^stages
    )
  end

  # ── The funnel ──────────────────────────────────────────────────────────────

  @doc """
  The funnel of one cohort (§4): the applications sent in `window`, and how
  many have since responded, reached an interview kind, an offer kind, or
  the outcome *Hired* — plus the purged leads applied on a day in `days`
  (`{first, last}`), from their fingerprints (a fingerprint knows no reply:
  it responded when it reached a response kind or ended with an answer).
  `%{applied, responded, interview, offer, hired}`.
  """
  @spec funnel(map(), {DateTime.t(), DateTime.t()}, {Date.t(), Date.t()}, map()) :: map()
  def funnel(subject, {from, to}, {first, last}, rules) do
    live =
      from(e in Event,
        as: :event,
        join: l in Lead,
        as: :lead,
        on: l.id == e.lead_id,
        join: j in assoc(l, :job),
        as: :job,
        left_join: r in subquery(reached(subject.organisation_id, rules)),
        on: r.lead_id == e.lead_id,
        where:
          e.organisation_id == ^subject.organisation_id and e.kind == :applied and
            e.occurred_at >= ^from and e.occurred_at < ^to,
        select: %{
          applied: count(e.id),
          responded: filter(count(e.id), r.responded_at >= e.occurred_at),
          interview: filter(count(e.id), r.interview_at >= e.occurred_at),
          offer: filter(count(e.id), r.offer_at >= e.occurred_at),
          hired: filter(count(e.id), r.hired_at >= e.occurred_at)
        }
      )
      |> narrow(subject)
      |> Repo.one()

    Map.merge(live, purged(subject, first, last, rules), fn _step, a, b -> a + b end)
  end

  defp purged(subject, first, last, rules) do
    [responses, interviews, offers] =
      Enum.map(
        [rules.response_kinds, rules.interview_kinds, rules.offer_kinds],
        &Enum.map(&1, fn kind -> to_string(kind) end)
      )

    from(f in Fingerprint,
      where:
        f.organisation_id == ^subject.organisation_id and f.applied_on >= ^first and
          f.applied_on <= ^last,
      select: %{
        applied: count(f.id),
        responded:
          filter(
            count(f.id),
            fragment("? && ?::text[]", f.stage_kinds, ^responses) or
              f.outcome in ^rules.answer_outcomes
          ),
        interview: filter(count(f.id), fragment("? && ?::text[]", f.stage_kinds, ^interviews)),
        offer: filter(count(f.id), fragment("? && ?::text[]", f.stage_kinds, ^offers)),
        hired: filter(count(f.id), f.outcome == :hired)
      }
    )
    |> fingerprint_teams(subject[:team_ids])
    |> fingerprint_customer(subject[:customer_id])
    |> Repo.one()
  end

  defp fingerprint_teams(query, nil), do: query
  defp fingerprint_teams(query, ids), do: where(query, [f], f.team_id in ^ids)

  defp fingerprint_customer(query, nil), do: query
  defp fingerprint_customer(query, id), do: where(query, [f], f.customer_id == ^id)

  # ── Triage ──────────────────────────────────────────────────────────────────

  @doc "How many triage items (no lead, not ignored) these teams hold."
  @spec triage_count([binary()]) :: non_neg_integer()
  def triage_count([]), do: 0
  def triage_count(team_ids), do: team_ids |> triage() |> Repo.aggregate(:count)

  @doc """
  Who each triage item of these teams is on (§4 *To sort in Triage*): the
  owners of the live profiles its receiving channel serves; when it serves
  none, the owners of its customer's live profiles. `[%{conversation_id,
  team_id, user_id}]`, each pair once; an item with neither is no one's.
  """
  @spec triage_owners([binary()]) :: [map()]
  def triage_owners([]), do: []

  def triage_owners(team_ids), do: team_ids |> triage_owner_rows() |> Repo.all()

  @doc """
  `triage_owners/1` as a query (`%{conversation_id, team_id, user_id}`
  rows): the Triage list's `profile_owner` filter (`Data.Filters.Triage`)
  reads the same rule the tile counts with.
  """
  @spec triage_owner_rows([binary()]) :: Ecto.Query.t()
  def triage_owner_rows(team_ids) do
    served =
      from(pc in ProfileChannel,
        join: p in Profile,
        on: p.id == pc.profile_id and is_nil(p.archived_at),
        select: pc.channel_id
      )

    via_customer =
      from(c in triage(team_ids),
        join: p in Profile,
        on: p.customer_id == c.customer_id and is_nil(p.archived_at),
        join: pm in ProfileMember,
        on: pm.profile_id == p.id,
        where: is_nil(c.channel_id) or c.channel_id not in subquery(served),
        select: %{conversation_id: c.id, team_id: c.team_id, user_id: pm.user_id}
      )

    from(c in triage(team_ids),
      join: pc in ProfileChannel,
      on: pc.channel_id == c.channel_id,
      join: p in Profile,
      on: p.id == pc.profile_id and is_nil(p.archived_at),
      join: pm in ProfileMember,
      on: pm.profile_id == p.id,
      select: %{conversation_id: c.id, team_id: c.team_id, user_id: pm.user_id},
      union: ^via_customer
    )
  end

  defp triage(team_ids) do
    linked = from(cl in ConversationLead, select: cl.conversation_id)

    from(c in Conversation,
      where: c.team_id in ^team_ids and is_nil(c.ignored_at) and c.id not in subquery(linked)
    )
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc false
  # Whose: the team, the owner, the customer, the profiles (every query
  # names its lead `:lead` and its job `:job`). `Data.Dashboards.Rows` too.
  def narrow(query, subject) do
    query
    |> teams(subject[:team_ids])
    |> owner(subject[:owner_user_id])
    |> profiles(subject[:profile_ids])
    |> customer(subject[:customer_id])
  end

  defp teams(query, nil), do: query
  defp teams(query, ids), do: where(query, [job: j], j.team_id in ^ids)

  defp owner(query, nil), do: query
  defp owner(query, id), do: where(query, [lead: l], l.owner_user_id == ^id)

  defp profiles(query, nil), do: query
  defp profiles(query, ids), do: where(query, [lead: l], l.profile_id in ^ids)

  defp customer(query, nil), do: query

  defp customer(query, customer_id) do
    query
    |> join(:inner, [lead: l], p in assoc(l, :profile), as: :profile)
    |> where([profile: p], p.customer_id == ^customer_id)
  end

  # One row, or one row per group, as `%{key => counts}`.
  defp grouped(query, nil, selects, windows) do
    query |> select(^selects) |> Repo.one() |> unflatten(windows)
  end

  defp grouped(query, group, selects, windows) do
    {query, by} = group_expr(query, group)

    query
    |> group_by(^[by])
    |> select(^Map.put(selects, "group", by))
    |> Repo.all()
    |> Enum.map(&Map.put(unflatten(&1, windows), :group, &1["group"]))
  end

  defp group_expr(query, :profile), do: {query, dynamic([lead: l], l.profile_id)}
  defp group_expr(query, :platform), do: {query, dynamic([job: j], j.source)}
  defp group_expr(query, :owner), do: {query, dynamic([lead: l], l.owner_user_id)}
  defp group_expr(query, :actor), do: {query, dynamic([event: e], e.actor_user_id)}

  defp group_expr(query, :skill) do
    query = join(query, :inner, [job: j], s in JobSkill, as: :skill, on: s.job_id == j.id)
    {query, dynamic([skill: s], s.skill_id)}
  end

  # `"today.count" => n` back to `%{today: %{count: n}}`; a bare key stays a number.
  defp unflatten(row, windows) do
    Map.new(windows, fn {key, _window} ->
      case Map.fetch(row, "#{key}") do
        {:ok, n} -> {key, n}
        :error -> {key, %{count: row["#{key}.count"], responses: row["#{key}.responses"]}}
      end
    end)
  end

  defp bounds(windows) do
    windows
    |> Map.values()
    |> Enum.reduce(fn {from, to}, {low, high} ->
      {Enum.min([from, low], DateTime), Enum.max([to, high], DateTime)}
    end)
  end
end
