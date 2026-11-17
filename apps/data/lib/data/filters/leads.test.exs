defmodule Data.Filters.LeadsTest do
  @moduledoc """
  `Data.Filters.Leads` (the board's and the Tracker's `$where`) through
  `Data.Leads.for_team/4`: each field and operator, each override against a
  direct query, the tile fields read as one `applied` row and agreeing with
  `Data.Dashboards.applications/4`, and the 422 for what the list doesn't
  take.
  """

  use Data.DataCase, async: true

  alias Data.Dashboards
  alias Data.Filters.TrackerSort
  alias Data.Leads
  alias Data.Leads.Lead

  @rules %{
    response_kinds: [:screening, :assessment, :interview, :ai_interview, :final, :offer],
    interview_kinds: [:assessment, :interview, :ai_interview, :final],
    offer_kinds: [:offer, :negotiation, :contract],
    answer_outcomes: [:rejected, :position_closed],
    interview_meetings: [:technical, :assessment_review, :ai_interview, :final],
    meeting_statuses: [:scheduled, :done, :no_show]
  }

  @now ~U[2026-11-14 10:00:00.000000Z]
  @zone "Asia/Karachi"

  setup do
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    bamboo = company_fixture(c.org, name: "Bamboo Invest")
    naveed = profile_fixture(c.naveed, title: "Golang")
    cv = document_fixture(c.golang, label: "Golang CV")

    paid =
      job_fixture(fs,
        team: c.backend,
        title: "Backend Developer",
        company: bamboo,
        comp_min_minor: 100,
        comp_currency: "USD",
        comp_period: :month,
        workplace: :remote,
        engagement: :full_time
      )

    applied =
      lead_fixture(fs,
        job: paid,
        profile: c.golang,
        as: :apply,
        document_id: cv.id,
        last_activity_at: ~U[2026-11-13 09:00:00.000000Z]
      )

    saved =
      lead_fixture(scope_for(c.qasim),
        job: job_fixture(fs, team: c.backend, title: "Another role", workplace: :on_site),
        profile: naveed,
        last_activity_at: ~U[2026-09-01 09:00:00.000000Z]
      )

    offer =
      lead_fixture(fs,
        job: job_fixture(fs, team: c.backend, title: "Offer role"),
        profile: c.golang,
        state: :in_progress,
        stage: "offer",
        last_activity_at: ~U[2026-11-12 09:00:00.000000Z]
      )

    done = lead_fixture(fs, team: c.backend, profile: c.golang, state: :done)
    archived = lead_fixture(fs, team: c.backend, profile: c.golang, archived: true)
    _elsewhere = lead_fixture(scope_for(c.hira), team: c.frontend)

    Map.merge(c, %{
      fs: fs,
      naveed_profile: naveed,
      applied: applied,
      saved: saved,
      offer: offer,
      done: done,
      archived: archived,
      live: Enum.sort([applied.id, saved.id, offer.id, done.id])
    })
  end

  defp context(c, extra \\ %{}) do
    Map.merge(
      %{user_id: c.fiza.id, organisation_id: c.org.id, now: @now, zone: @zone, rules: @rules},
      extra
    )
  end

  defp run(c, where, extra \\ %{}), do: Leads.for_team(c.backend.id, where, context(c, extra))

  defp ids(c, where, extra \\ %{}) do
    {:ok, leads} = run(c, where, extra)
    leads |> Enum.map(& &1.id) |> Enum.sort()
  end

  # The team's live leads a hand-written query keeps.
  defp direct(c, query) do
    from(l in query,
      join: j in assoc(l, :job),
      where: j.team_id == ^c.backend.id and is_nil(l.archived_at),
      select: l.id
    )
    |> Repo.all()
    |> Enum.sort()
  end

  defp event(c, lead, kind, at, attrs) do
    {:ok, e} =
      %{
        organisation_id: c.org.id,
        lead_id: lead.id,
        kind: kind,
        occurred_at: at,
        recorded_at: at,
        actor_kind: :user,
        actor_user_id: c.fiza.id,
        visibility: :customer
      }
      |> Map.merge(Map.new(attrs))
      |> Leads.add_event()

    e
  end

  test "no $where: the team's live leads, newest activity first", c do
    assert {:ok, leads} = run(c, nil)
    assert Enum.map(leads, & &1.id) |> Enum.sort() == c.live
    assert ids(c, %{}) == c.live
  end

  test "state: $EQUAL, $NOT_EQUAL, $IN, $NOT_IN", c do
    assert ids(c, %{"state" => %{"$EQUAL" => "todo"}}) == [c.saved.id]
    assert ids(c, %{"state" => "done"}) == [c.done.id]

    assert ids(c, %{"state" => %{"$NOT_EQUAL" => "in_progress"}}) ==
             Enum.sort([c.saved.id, c.done.id])

    assert ids(c, %{"state" => %{"$IN" => ["todo", "done"]}}) ==
             Enum.sort([c.saved.id, c.done.id])

    assert ids(c, %{"state" => %{"$NOT_IN" => ["todo", "done"]}}) ==
             Enum.sort([c.applied.id, c.offer.id])
  end

  test "profile, customer: $EQUAL and $IN", c do
    assert ids(c, %{"profile" => %{"$EQUAL" => c.naveed_profile.id}}) == [c.saved.id]
    golang = Enum.sort([c.applied.id, c.offer.id, c.done.id])
    assert ids(c, %{"profile" => %{"$IN" => [c.golang.id]}}) == golang
    assert ids(c, %{"profile" => c.golang.id}) == golang
    assert ids(c, %{"customer" => %{"$EQUAL" => c.naveed.id}}) == [c.saved.id]
    assert ids(c, %{"customer" => %{"$IN" => [c.naveed.id, c.tanweer.id]}}) == c.live
  end

  test "source, engagement, workplace (the job's), stage and pipeline", c do
    assert ids(c, %{"workplace" => %{"$EQUAL" => "remote"}}) == [c.applied.id]

    assert ids(c, %{"workplace" => %{"$IN" => ["remote", "on_site"]}}) ==
             Enum.sort([c.applied.id, c.saved.id])

    assert ids(c, %{"engagement" => %{"$IN" => ["full_time"]}}) == [c.applied.id]
    assert ids(c, %{"source" => %{"$EQUAL" => "company_site"}}) == c.live
    assert ids(c, %{"source" => %{"$IN" => ["upwork"]}}) == []
    assert ids(c, %{"stage" => %{"$EQUAL" => "offer"}}) == [c.offer.id]
    assert ids(c, %{"stage" => %{"$IN" => ["offer", "applied"]}}) |> Enum.member?(c.offer.id)
    assert ids(c, %{"pipeline" => %{"$EQUAL" => "employment"}}) == c.live
    assert ids(c, %{"pipeline" => %{"$EQUAL" => "freelance"}}) == []
  end

  test "owner: me or ids; label: the team's, any of them; archived", c do
    assert ids(c, %{"owner" => %{"$EQUAL" => "me"}}) ==
             Enum.sort([c.applied.id, c.offer.id, c.done.id])

    assert ids(c, %{"owner" => %{"$IN" => [c.qasim.id]}}) == [c.saved.id]
    assert ids(c, %{"owner" => %{"$IN" => ["me", c.qasim.id]}}) == c.live

    label = label_fixture(c.fs, c.backend)
    other = label_fixture(c.fs, c.backend)
    Data.Labels.put_for_lead(c.offer.id, [label.id])
    assert ids(c, %{"label" => %{"$EQUAL" => label.id}}) == [c.offer.id]
    assert ids(c, %{"label" => %{"$IN" => [label.id, other.id]}}) == [c.offer.id]

    theirs = label_fixture(scope_for(c.hira), c.frontend)

    assert {:error, {:invalid_filter, %{"label" => _}}} =
             run(c, %{"label" => %{"$IN" => [theirs.id]}})

    assert ids(c, %{"archived" => %{"$EQUAL" => "true"}}) == [c.archived.id]
    assert ids(c, %{"archived" => %{"$EQUAL" => false}}) == c.live

    assert ids(c, %{"archived" => %{"$IN" => ["true", "false"]}}) ==
             Enum.sort([c.archived.id | c.live])

    assert ids(c, %{"archived" => %{"$IN" => [true]}}) == [c.archived.id]

    assert {:error, {:invalid_filter, %{"archived" => _}}} =
             run(c, %{"archived" => %{"$IN" => [true, "maybe"]}})
  end

  test "q, quiet, missing, stage_kind against direct queries", c do
    like = "%backend%"

    assert ids(c, %{"q" => %{"$ILIKE" => "Backend"}}) ==
             direct(
               c,
               from(l in Lead,
                 join: j in assoc(l, :job),
                 left_join: co in assoc(j, :company),
                 where:
                   fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or
                     like(co.name_normalized, ^like)
               )
             )

    assert ids(c, %{"q" => %{"$ILIKE" => "%bamboo%"}}) == [c.applied.id]

    cutoff = DateTime.add(@now, -30 * 86_400, :second)

    assert ids(c, %{"quiet" => %{"$EQUAL" => "30"}}) ==
             direct(c, from(l in Lead, where: l.last_activity_at < ^cutoff))

    assert ids(c, %{"quiet" => %{"$EQUAL" => 60}}) == [c.saved.id]

    no_money =
      direct(
        c,
        from(l in Lead,
          join: j in assoc(l, :job),
          where: is_nil(j.comp_min_minor) and is_nil(j.comp_max_minor)
        )
      )

    assert ids(c, %{"missing" => %{"$EQUAL" => "money"}}) == no_money

    assert ids(c, %{"missing" => %{"$IN" => ["cv"]}}) ==
             direct(c, from(l in Lead, where: is_nil(l.document_id)))

    assert ids(c, %{"missing" => %{"$IN" => ["money", "cv"]}}) ==
             direct(
               c,
               from(l in Lead,
                 join: j in assoc(l, :job),
                 where:
                   (is_nil(j.comp_min_minor) and is_nil(j.comp_max_minor)) or
                     is_nil(l.document_id)
               )
             )

    reached = fn kinds ->
      direct(
        c,
        from(l in Lead,
          join: s in assoc(l, :stage),
          where:
            (s.kind != :custom and s.kind in ^kinds) or
              (s.kind == :custom and s.anchor_kind in ^kinds)
        )
      )
    end

    assert ids(c, %{"stage_kind" => %{"$IN" => ["offer", "negotiation"]}}) ==
             reached.([:offer, :negotiation])

    assert ids(c, %{"stage_kind" => %{"$EQUAL" => "applied"}}) == reached.([:applied])
    assert ids(c, %{"stage_kind" => %{"$EQUAL" => "offer"}}) == [c.offer.id]
  end

  test "follow_up due: the SQL half of P4b's rule, In progress and live", c do
    assert ids(c, %{"follow_up" => %{"$EQUAL" => "due"}}) ==
             direct(c, from(l in Lead, where: l.state == :in_progress))
  end

  describe "the tile fields" do
    setup c do
      # Applied Friday (13th, Karachi) and Saturday (14th) by Fiza; Qasim
      # applied the offer lead on the 14th too; the applied lead heard back.
      event(c, c.applied, :applied, ~U[2026-11-13 06:00:00.000000Z], stage_kind: :applied)
      event(c, c.offer, :applied, ~U[2026-11-14 06:00:00.000000Z], stage_kind: :applied)

      event(c, c.done, :applied, ~U[2026-11-14 07:00:00.000000Z],
        stage_kind: :applied,
        actor_user_id: c.qasim.id
      )

      event(c, c.applied, :stage_moved, ~U[2026-11-14 08:00:00.000000Z], stage_kind: :screening)
      :ok
    end

    test "applied_on: local days, both kept, in the zone; $EQUAL one day", c do
      assert ids(c, %{"applied_on" => %{"$BETWEEN" => ["2026-11-14", "2026-11-14"]}}) ==
               Enum.sort([c.offer.id, c.done.id])

      assert ids(c, %{"applied_on" => %{"$EQUAL" => "2026-11-13"}}) == [c.applied.id]

      assert ids(c, %{"applied_on" => %{"$BETWEEN" => ["2026-11-13", "2026-11-14"]}}) ==
               Enum.sort([c.applied.id, c.offer.id, c.done.id])

      # 01:00 on the 14th in Karachi is still the 13th in UTC.
      late = lead_fixture(c.fs, team: c.backend, profile: c.golang, as: :apply)
      event(c, late, :applied, ~U[2026-11-13 20:00:00.000000Z], stage_kind: :applied)
      assert late.id in ids(c, %{"applied_on" => %{"$EQUAL" => "2026-11-14"}})
      refute late.id in ids(c, %{"applied_on" => %{"$EQUAL" => "2026-11-14"}}, %{zone: "Etc/UTC"})
    end

    test "applied_by: me or an id, the ledger's actor", c do
      assert ids(c, %{"applied_by" => %{"$EQUAL" => "me"}}) ==
               Enum.sort([c.applied.id, c.offer.id])

      assert ids(c, %{"applied_by" => %{"$EQUAL" => c.qasim.id}}) == [c.done.id]
    end

    test "had_response: AQ-11 §4's rule, as Data.Dashboards counts it", c do
      assert ids(c, %{"had_response" => %{"$EQUAL" => "true"}}) == [c.applied.id]

      assert ids(c, %{"had_response" => %{"$EQUAL" => false}}) ==
               Enum.sort([c.offer.id, c.done.id])
    end

    test "read as one applied row, they agree with Data.Dashboards.applications/4", c do
      for {first, last} <- [
            {~D[2026-11-13], ~D[2026-11-13]},
            {~D[2026-11-13], ~D[2026-11-14]},
            {~D[2026-11-14], ~D[2026-11-14]}
          ],
          actor <- [c.fiza.id, c.qasim.id] do
        window = Utils.Days.window(first, last, @zone)
        subject = %{organisation_id: c.org.id, team_ids: [c.backend.id], actor_user_id: actor}

        %{w: %{count: count, responses: responses}} =
          Dashboards.applications(subject, %{w: window}, @rules)

        base = %{
          "applied_on" => %{"$BETWEEN" => [Date.to_iso8601(first), Date.to_iso8601(last)]},
          "applied_by" => %{"$EQUAL" => actor}
        }

        assert length(ids(c, base)) == count

        assert length(ids(c, Map.put(base, "had_response", %{"$EQUAL" => true}))) == responses
      end
    end

    test "applied_spec/2 and applied_rows/1: the rows the tiles count, a lead applied twice twice",
         c do
      event(c, c.offer, :applied, ~U[2026-11-14 09:00:00.000000Z], stage_kind: :applied)

      assert Data.Filters.Leads.applied_spec(%{"owner" => %{"$EQUAL" => "me"}}, context(c)) == nil
      assert Data.Filters.Leads.applied_spec(nil, context(c)) == nil

      for {first, last} <- [{~D[2026-11-13], ~D[2026-11-14]}, {~D[2026-11-14], ~D[2026-11-14]}],
          responded <- [nil, true] do
        where =
          %{
            "applied_on" => %{"$BETWEEN" => [Date.to_iso8601(first), Date.to_iso8601(last)]},
            "applied_by" => %{"$EQUAL" => "me"}
          }
          |> then(&if(responded, do: Map.put(&1, "had_response", %{"$EQUAL" => true}), else: &1))

        subject = %{organisation_id: c.org.id, team_ids: [c.backend.id], actor_user_id: c.fiza.id}
        window = Utils.Days.window(first, last, @zone)
        %{w: tile} = Dashboards.applications(subject, %{w: window}, @rules)

        listed = ids(c, where)
        counted = Leads.applications(listed, where, context(c))
        assert counted == if(responded, do: tile.responses, else: tile.count)
        assert length(listed) <= counted
      end

      assert Leads.applications([], %{"applied_by" => %{"$EQUAL" => "me"}}, context(c)) == 0
      assert Leads.applications(c.live, %{"state" => "todo"}, context(c)) == nil
    end

    test "a response before the application in the window doesn't count for it", c do
      # Applied again on the 14th after the screening move: that row has no response yet.
      event(c, c.applied, :applied, ~U[2026-11-14 09:00:00.000000Z], stage_kind: :applied)

      where = %{
        "applied_on" => %{"$EQUAL" => "2026-11-14"},
        "had_response" => %{"$EQUAL" => true}
      }

      assert ids(c, where) == []
      assert c.applied.id in ids(c, %{"had_response" => %{"$EQUAL" => true}})
    end
  end

  test "interviewed_on: Data.Dashboards' interview rule, the same leads as interviews/4 counts",
       c do
    # On the 14th: a stage of an interview kind (applied), a technical
    # meeting (offer), a cancelled one and a screening call (saved, not
    # counted); on the 13th the archived lead reached the final stage.
    event(c, c.applied, :stage_moved, ~U[2026-11-14 05:00:00.000000Z], stage_kind: :interview)
    meeting_fixture(c.fs, lead: c.offer, starts_at: ~U[2026-11-14 06:00:00.000000Z])

    meeting_fixture(c.fs,
      lead: c.saved,
      starts_at: ~U[2026-11-14 07:00:00.000000Z],
      status: :cancelled
    )

    meeting_fixture(c.fs,
      lead: c.saved,
      starts_at: ~U[2026-11-14 08:00:00.000000Z],
      meeting_kind: :screening
    )

    event(c, c.archived, :stage_moved, ~U[2026-11-13 05:00:00.000000Z], stage_kind: :final)

    both = %{"archived" => %{"$IN" => [true, false]}}

    for {first, last} <- [
          {~D[2026-11-14], ~D[2026-11-14]},
          {~D[2026-11-13], ~D[2026-11-14]},
          {~D[2026-11-12], ~D[2026-11-12]}
        ],
        owner <- [c.fiza.id, c.qasim.id] do
      window = Utils.Days.window(first, last, @zone)
      subject = %{organisation_id: c.org.id, team_ids: [c.backend.id], owner_user_id: owner}
      %{w: count} = Dashboards.interviews(subject, %{w: window}, @rules)

      where =
        Map.merge(both, %{
          "interviewed_on" => %{"$BETWEEN" => [Date.to_iso8601(first), Date.to_iso8601(last)]},
          "owner" => %{"$EQUAL" => owner}
        })

      assert length(ids(c, where)) == count, "#{first}..#{last}"
    end

    assert ids(c, %{"interviewed_on" => %{"$EQUAL" => "2026-11-14"}}) ==
             Enum.sort([c.applied.id, c.offer.id])

    assert ids(c, Map.put(both, "interviewed_on", %{"$EQUAL" => "2026-11-13"})) == [c.archived.id]

    assert {:error, {:invalid_filter, %{"interviewed_on" => _}}} =
             run(c, %{"interviewed_on" => %{"$BETWEEN" => ["2026-11-14", "2026-11-13"]}})

    assert {:error, {:invalid_filter, %{"interviewed_on" => _}}} =
             run(c, %{"interviewed_on" => %{"$EQUAL" => "2026-11-14"}}, %{rules: nil})
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"outcome" => "rejected"}, "outcome"},
          {%{"state" => %{"$GT" => "todo"}}, "state"},
          {%{"state" => "nope"}, "state"},
          {%{"quiet" => %{"$EQUAL" => "7"}}, "quiet"},
          {%{"missing" => %{"$IN" => ["recruiter"]}}, "missing"},
          {%{"owner" => %{"$EQUAL" => "someone"}}, "owner"},
          {%{"stage_kind" => %{"$IN" => ["lunch"]}}, "stage_kind"},
          {%{"applied_on" => %{"$BETWEEN" => ["2026-11-14"]}}, "applied_on"},
          {%{"applied_on" => %{"$BETWEEN" => ["2026-11-15", "2026-11-14"]}}, "applied_on"},
          {%{"applied_by" => %{"$IN" => ["me"]}}, "applied_by"},
          {%{"had_response" => %{"$EQUAL" => "maybe"}}, "had_response"},
          {%{"follow_up" => %{"$EQUAL" => "late"}}, "follow_up"},
          {%{"pipeline" => %{"$IN" => ["employment"]}}, "pipeline"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} = run(c, where), inspect(where)
    end

    assert {:error, {:invalid_filter, %{"had_response" => _}}} =
             run(c, %{"had_response" => %{"$EQUAL" => true}}, %{rules: nil})
  end

  test "visible_to keeps a member's own; order adds ties by id", c do
    {:ok, own} = Leads.for_team(c.backend.id, nil, context(c), visible_to: c.qasim.id)
    assert Enum.map(own, & &1.id) == [c.saved.id]

    order = TrackerSort.build(%{"title" => "$ASC"})
    {:ok, sorted} = Leads.for_team(c.backend.id, nil, context(c), order: order)
    titles = Enum.map(sorted, &String.downcase(&1.job.title))
    assert titles == Enum.sort(titles)
  end
end
