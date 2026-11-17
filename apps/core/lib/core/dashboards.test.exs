defmodule Core.DashboardsTest do
  @moduledoc """
  AQ-11 P11.0 and P11.2: *My numbers*, **each number against a direct
  count** — the ledger's rows counted in SQL, or the rule applied by hand
  to the rows — for a week of Fiza's work made through the verbs; the
  zone's day edges; who may ask (§6); a lead she may not see counted in
  her tiles but never listed.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Dashboards
  alias Data.Leads.Event

  # Thursday 12 Nov 2026, 12:00 in Karachi (UTC+5).
  @now ~U[2026-11-12 07:00:00.000000Z]
  # This week: Monday 9 Nov 00:00 to Monday 16 Nov 00:00 in Karachi.
  @week {~U[2026-11-08 19:00:00.000000Z], ~U[2026-11-15 19:00:00.000000Z]}
  @today {~U[2026-11-11 19:00:00.000000Z], ~U[2026-11-12 19:00:00.000000Z]}

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    rust = profile_fixture(c.naveed, title: "Rust backend", owners: [c.fiza], daily_target: 10)
    job = fn title -> job_fixture(fs, team: c.backend, title: title) end

    # Last week, a minute before the week; this week, a minute into it.
    la = apply_at(fs, job.("A"), c.golang, ~U[2026-11-08 18:30:00.000000Z])
    lb = apply_at(fs, job.("B"), c.golang, ~U[2026-11-08 19:00:30.000000Z])
    lc = apply_at(fs, job.("C"), c.golang, ~U[2026-11-12 04:00:00.000000Z])
    ld = apply_at(fs, job.("D"), rust, ~U[2026-11-12 05:00:00.000000Z])
    le = apply_at(scope_for(c.qasim), job.("E"), c.golang, ~U[2026-11-12 06:00:00.000000Z])
    lf = apply_at(fs, job.("F"), c.golang, ~U[2026-11-06 05:00:00.000000Z])

    # Responses: a reply, a move to an interview, a rejection; the customer's
    # own message is none.
    reply_at(fs, la, ~U[2026-11-09 04:00:00.000000Z])
    reply_at(fs, lb, ~U[2026-11-10 05:00:00.000000Z])
    verb_at(fs, :apply_again, lb, %{"reason" => "New CV"}, ~U[2026-11-11 05:00:00.000000Z])

    verb_at(
      fs,
      :move,
      lc,
      %{"state" => "in_progress", "stage" => "technical_1"},
      ~U[2026-11-12 06:30:00.000000Z]
    )

    verb_at(fs, :finish, ld, %{"outcome" => "rejected"}, ~U[2026-11-12 06:45:00.000000Z])
    reply_at(fs, le, ~U[2026-11-12 06:50:00.000000Z], from_kind: :customer)

    # Meetings: an interview on Friday; a call today; a screening next week;
    # a cancelled interview.
    meeting_fixture(fs,
      lead: la,
      meeting_kind: :technical,
      starts_at: ~U[2026-11-13 05:00:00.000000Z]
    )

    meeting_fixture(fs,
      lead: lb,
      meeting_kind: :client_call,
      starts_at: ~U[2026-11-12 11:00:00.000000Z]
    )

    meeting_fixture(fs,
      lead: lb,
      meeting_kind: :screening,
      starts_at: ~U[2026-11-17 05:00:00.000000Z]
    )

    meeting_fixture(fs,
      lead: ld,
      meeting_kind: :technical,
      status: :cancelled,
      starts_at: ~U[2026-11-12 09:00:00.000000Z]
    )

    Map.merge(c, %{fs: fs, rust: rust, la: la, lb: lb, lc: lc, ld: ld, le: le, lf: lf})
  end

  defp count_applied(user_id, {from, to}) do
    from(e in Event,
      where:
        e.kind == :applied and e.actor_user_id == ^user_id and e.occurred_at >= ^from and
          e.occurred_at < ^to
    )
    |> Repo.aggregate(:count)
  end

  # §4's rule by hand: an application responded when a reply (not the
  # customer's), a move past Applied or a rejection came at or after it.
  defp responded_by_hand(user_id, {from, to}) do
    applied =
      Repo.all(
        from(e in Event,
          where:
            e.kind == :applied and e.actor_user_id == ^user_id and e.occurred_at >= ^from and
              e.occurred_at < ^to
        )
      )

    Enum.count(applied, fn a ->
      from(r in Event, where: r.lead_id == ^a.lead_id and r.occurred_at >= ^a.occurred_at)
      |> Repo.all()
      |> Repo.preload(:message)
      |> Enum.any?(&response?/1)
    end)
  end

  defp response?(%{kind: :message_in, message: m}), do: m.from_kind != :customer
  defp response?(%{kind: :stage_moved, stage_kind: k}), do: k not in [:inbound, :applied, :seen]
  defp response?(%{kind: :outcome_set, outcome: o}), do: o in [:rejected, :position_closed]
  defp response?(_event), do: false

  test "every tile of the week equals a direct count", c do
    {:ok, me} = Dashboards.me(c.fs, %{"period" => "week"}, @now)

    assert me.period == %{
             key: :week,
             from: ~D[2026-11-09],
             to: ~D[2026-11-15],
             label: "This week"
           }

    assert me.person == %{id: c.fiza.id, name: "Fiza"}

    # Mon (a minute in), Wed (again), Thu twice; not last Sunday's, not Qasim's.
    assert me.tiles.applications == count_applied(c.fiza.id, @week)
    assert me.tiles.applications == 4
    assert me.target.done_today == count_applied(c.fiza.id, @today)
    assert me.target.done_today == 2

    assert me.tiles.responses ==
             %{count: responded_by_hand(c.fiza.id, @week), of: 4, rate_bp: 7500, few: true}

    assert me.tiles.responses.count == 3

    # C reached an interview stage; A has an interview meeting on Friday.
    assert me.tiles.interviews == 2

    # F waits on its first follow-up; A and B were answered, C is past Applied.
    assert me.tiles.follow_ups_due == 1

    assert me.by_profile |> Enum.map(&{&1.profile.title, &1.count}) ==
             [{"Golang backend", 3}, {"Rust backend", 1}]

    assert me.by_platform == [%{platform: :company_site, count: 4}]
  end

  test "the run: this week's working days to today, with the target", c do
    {:ok, me} = Dashboards.me(c.fs, %{}, @now)

    assert me.period.key == :today
    assert me.tiles.applications == 2
    # Golang (35) and Rust (10), both served by Backend.
    assert me.target.today == 45

    assert me.target.run == [
             %{on: ~D[2026-11-09], done: 1, target: 45},
             %{on: ~D[2026-11-10], done: 0, target: 45},
             %{on: ~D[2026-11-11], done: 1, target: 45},
             %{on: ~D[2026-11-12], done: 2, target: 45}
           ]
  end

  test "what is open now: follow-ups, Triage, approvals, tasks, and the day's list", c do
    channel = channel_fixture(c.tanweer)
    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    on_channel = conversation_fixture(c.fs, team: c.backend)
    {:ok, _} = Data.Conversations.update(on_channel, %{channel_id: channel.id})
    _by_customer = conversation_fixture(c.fs, team: c.backend, customer: c.tanweer)
    _nobodys = conversation_fixture(c.fs, team: c.backend)
    _linked = conversation_fixture(c.fs, lead: c.la)

    due = ~U[2026-11-12 10:00:00.000000Z]
    hs = scope_for(c.hira)

    mine =
      approval_fixture(hs, lead: c.lc, state: :pending, slots: [{:user, c.fiza}], due_at: due)

    _theirs = approval_fixture(hs, lead: c.lc, state: :pending, slots: [{:user, c.qasim}])

    today = task_fixture(c.fs, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-12])
    late = task_fixture(c.fs, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-10])
    task_fixture(c.fs, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-13])
    task_fixture(c.fs, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-12], state: :done)

    {:ok, me} = Dashboards.me(c.fs, %{"period" => "week"}, @now)

    assert me.tiles.triage == 2
    assert {%{}, 3} = Dashboards.triage(c.fs, [c.backend.id])
    assert me.tiles.approvals_waiting == 1
    assert me.tiles.tasks_due == 2

    assert Enum.map(me.due_today, &{&1.kind, &1.id}) == [
             {"follow_up", c.lf.id},
             {"task", late.id},
             {"task", today.id},
             {"approval", mine.id},
             {"meeting", hd(Data.Meetings.for_lead(c.lb.id)).id}
           ]

    assert %{line: "Overdue since 10 Nov", link_path: "/board/" <> _} =
             Enum.find(me.due_today, &(&1.id == late.id))

    assert Enum.map(me.upcoming_meetings, & &1.lead.id) == [c.lb.id, c.la.id, c.lb.id]

    assert Enum.map(me.recent_applications, & &1.lead_id) ==
             [c.ld.id, c.lc.id, c.lb.id, c.lb.id, c.la.id, c.lf.id]

    assert %{
             state: :done,
             stage: %{key: "applied", label: "Applied"},
             profile: %{title: "Rust backend"}
           } =
             hd(me.recent_applications)
  end

  test "about to archive: their leads that archive within 7 days", c do
    quiet =
      lead_fixture(c.fs,
        team: c.backend,
        profile: c.golang,
        last_activity_at: ~U[2026-08-19 07:00:00.000000Z]
      )

    lead_fixture(c.fs,
      team: c.backend,
      profile: c.golang,
      last_activity_at: ~U[2026-09-30 07:00:00.000000Z]
    )

    {:ok, me} = Dashboards.me(c.fs, %{}, @now)
    assert [%{lead_id: id, archives_on: ~D[2026-11-17]}] = me.about_to_archive
    assert id == quiet.id
  end

  test "the zone's day edges: a minute either side of midnight in Karachi", c do
    {:ok, me} = Dashboards.me(c.fs, %{"period" => "week"}, @now)
    lb_first = c.lb.id

    # B's first application, 00:00:30 on Monday, is in; A's, 23:30 on Sunday, is not.
    assert lb_first in Enum.map(me.recent_applications, & &1.lead_id)
    assert me.target.run |> hd() |> Map.fetch!(:done) == 1

    {:ok, sunday} = Dashboards.me(c.fs, %{}, ~U[2026-11-08 18:59:00.000000Z])
    assert sunday.target.done_today == 1
    assert sunday.target.today == nil
  end

  test "who may ask (§6): staff their own; a customer finds nothing", c do
    assert {:ok, _me} = Dashboards.me(scope_for(c.qasim), %{}, @now)
    assert {:ok, _me} = Dashboards.me(scope_for(c.hira), %{}, @now)
    assert {:error, :not_found} = Dashboards.me(customer_scope_for(c.tanweer), %{}, @now)

    assert {:error, {:invalid, %{"period" => _}}} =
             Dashboards.me(c.fs, %{"period" => "year"}, @now)
  end

  test "a lead the person may not see counts in their tiles, never in their lists", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    ms = scope_for(c.muaz)
    hidden = lead_fixture(ms, team: c.backend, profile: c.golang, as: :apply)

    # Qasim applied before Muaz took it on and applied again.
    {:ok, _} =
      Data.Leads.add_event(%{
        organisation_id: c.org.id,
        lead_id: hidden.id,
        kind: :applied,
        stage_kind: :applied,
        occurred_at: ~U[2026-11-12 06:10:00.000000Z],
        recorded_at: ~U[2026-11-12 06:10:00.000000Z],
        actor_kind: :user,
        actor_user_id: c.qasim.id,
        visibility: :customer
      })

    qs = scope_for(c.qasim)
    refute Core.Access.can?(qs, :read, {:lead, Core.Leads.subject(Data.Leads.reload(hidden))})

    {:ok, me} = Dashboards.me(qs, %{}, @now)
    assert me.tiles.applications == count_applied(c.qasim.id, @today)
    assert me.tiles.applications == 2
    assert Enum.map(me.recent_applications, & &1.lead_id) == [c.le.id]
  end
end
