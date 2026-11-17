defmodule Core.BehaviourTest do
  @moduledoc """
  AQ-10 P10.0–P10.2's reads: a subject's summary and page (the sentence,
  the heat map in both zones, the timeline by keyset, the jobs) and the
  Behaviour list (what the team touches, newest last seen first, watched
  by me, a name), with their refusals. The writers are
  `Core.Behaviour.SourcesTest`'s, the routes that log one
  `Core.Behaviour.LogTest`'s, *Forget* and the sweep
  `Core.Behaviour.PrivacyTest`'s.
  """

  use Core.CoreCase, async: true

  alias Core.Behaviour

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{fs: scope_for(c.fiza), ext: %{scope_for(c.fiza) | via: :extension}})
  end

  describe "reads" do
    test "the summary and the page: sentence, heat in both zones, the timeline by keyset", c do
      corvid = company_fixture(c.org, name: "Corvid Security")
      _job = job_fixture(c.fs, team: c.backend, company: corvid, title: "Go")
      {:ok, corvid} = Data.Companies.put_zone(corvid, "America/New_York", :manual)

      for day <- 0..34 do
        at =
          DateTime.add(
            ~U[2026-11-10 09:00:00.000000Z],
            div(day, 5) * 3600 + rem(day, 5) * 86_400,
            :second
          )

        {:ok, _} =
          Behaviour.observe(c.fs, %{
            company_id: corvid.id,
            kind: :seen_online,
            source: :manual,
            observed_at: at,
            active_at: at
          })
      end

      assert {:ok, page} = Behaviour.page(c.fs, "company", corvid.id, @now)

      assert page.subject == %{
               kind: :company,
               id: corvid.id,
               name: "Corvid Security",
               company: nil
             }

      assert page.behaviour.seen == 35 and page.behaviour.enough
      assert page.behaviour.sentence =~ "Usually online"

      assert page.behaviour.time_zone == "America/New_York" and
               page.behaviour.time_zone_source == :manual

      assert page.heat.ours.zone == "Asia/Karachi" and page.heat.theirs.zone == "America/New_York"
      assert length(page.observations.items) == 30 and is_binary(page.observations.next_cursor)
      assert [%{id: _, title: "Go"}] = page.jobs

      assert {:ok, %{items: rest, next_cursor: nil}} =
               Behaviour.observations(c.fs, "company", corvid.id, %{
                 "cursor" => page.observations.next_cursor
               })

      assert length(rest) == 5

      assert {:error, :not_found} = Behaviour.page(c.fs, "lead", corvid.id, @now)

      assert {:error, :not_found} =
               Behaviour.page(customer_scope_for(c.tanweer), "company", corvid.id, @now)
    end

    test "the list: what the team touches, newest last seen first, watched by me, a name", c do
      corvid = company_fixture(c.org, name: "Corvid Security")
      bamboo = company_fixture(c.org, name: "Bamboo Invest")
      _ = job_fixture(c.fs, team: c.backend, company: corvid)
      _ = job_fixture(scope_for(c.hira), team: c.frontend, company: bamboo)

      for {company, at} <- [
            {corvid, ~U[2026-11-13 09:00:00Z]},
            {bamboo, ~U[2026-11-14 09:00:00Z]}
          ] do
        {:ok, _} =
          Behaviour.observe(c.fs, %{
            company_id: company.id,
            kind: :seen_online,
            source: :manual,
            observed_at: at,
            active_at: at
          })
      end

      {:ok, backend} = Behaviour.list(c.fs, %{"team_id" => c.backend.id}, @now)

      assert [%{subject: %{name: "Corvid Security"}, watching: false, watchers_count: 0}] =
               backend.items

      {:ok, all} = Behaviour.list(scope_for(c.dawud), %{}, @now)
      assert Enum.map(all.items, & &1.subject.name) == ["Bamboo Invest", "Corvid Security"]

      {:ok, {:created, _}} =
        Core.Watches.create(c.fs, %{"company_id" => corvid.id, "trigger" => "posts_job"}, @now)

      {:ok, mine} =
        Behaviour.list(
          c.fs,
          %{"team_id" => c.backend.id, "$where" => %{"watched" => %{"$EQUAL" => "me"}}},
          @now
        )

      assert [%{watching: true, watchers_count: 1, leads_open: 0}] = mine.items

      where = &Behaviour.list(c.fs, %{"team_id" => c.backend.id, "$where" => &1}, @now)
      assert {:ok, %{items: []}} = where.(%{"q" => %{"$ILIKE" => "bamboo"}})
      assert {:ok, %{items: [_corvid]}} = where.(%{"q" => %{"$ILIKE" => "corvid"}})
      assert {:ok, %{items: []}} = where.(%{"kind" => %{"$EQUAL" => "contact"}})
      assert {:ok, %{items: [_corvid]}} = where.(%{"kind" => %{"$IN" => ["company", "contact"]}})
      assert {:error, {:invalid_filter, %{"kind" => _}}} = where.(%{"kind" => "lead"})
      assert {:error, {:invalid_filter, %{"watched" => _}}} = where.(%{"watched" => c.hira.id})

      assert {:error, {:invalid, %{"team_id" => _}}} = Behaviour.list(c.fs, %{}, @now)
      assert {:error, :not_found} = Behaviour.list(customer_scope_for(c.tanweer), %{}, @now)
    end
  end
end
