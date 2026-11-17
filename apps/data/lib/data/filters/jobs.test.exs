defmodule Data.Filters.JobsTest do
  @moduledoc """
  `Data.Filters.Jobs` (the pool's `$where`): each field and operator, each
  override against a direct query, and the 422s; `Data.Filters.JobsSort`'s
  allowlist and orders.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Filters.{Jobs, JobsSort}
  alias Data.Jobs.{Job, JobSkill, Merge}
  alias Data.Leads.Lead

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    scope = scope_for(cast.fiza)
    tux = company_fixture(cast.org, name: "TuxCare")
    go = skill_fixture(cast.org, name: "Go")
    j = fn title, attrs -> job_fixture(scope, Keyword.merge([title: title], attrs)) end

    jobs = %{
      monthly:
        j.("Go Engineer",
          comp_max_minor: 550_000,
          comp_currency: "USD",
          comp_period: :month,
          workplace: :remote,
          remote_scope: :global,
          posted_on: ~D[2026-11-09],
          skills: [{go, true}]
        ),
      hourly:
        j.("Elixir Developer",
          comp_max_minor: 6_000,
          comp_currency: "USD",
          comp_period: :hour,
          workplace: :remote,
          remote_scope: :country_list,
          allowed_countries: ["PK"],
          url: "https://www.upwork.com/jobs/~01aa",
          first_seen_at: ~U[2026-11-08 10:00:00.000000Z]
        ),
      pounds:
        j.("Staff Engineer",
          comp_max_minor: 9_000_000,
          comp_currency: "GBP",
          comp_period: :year,
          company: tux,
          first_seen_at: ~U[2026-10-01 10:00:00.000000Z]
        ),
      fixed:
        j.("Café app",
          comp_max_minor: 150_000,
          comp_currency: "USD",
          comp_period: :project,
          engagement: :freelance_fixed,
          first_seen_at: ~U[2026-10-01 10:00:00.000000Z]
        ),
      archived: j.("Old role", archived: true)
    }

    Map.merge(cast, %{scope: scope, jobs: jobs, go: go, tux: tux})
  end

  defp base(c), do: from(j in Job, as: :job, where: j.team_id == ^c.backend.id)

  defp ids(c, where, context \\ %{}) do
    {:ok, query} = Filters.where(base(c), Jobs, where, Map.put_new(context, :now, @now))
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  defp sorted(jobs), do: jobs |> Enum.map(& &1.id) |> Enum.sort()

  test "the columns: $EQUAL and $IN on each key", c do
    for {field, column, values} <- [
          {"source", :source, ["upwork", "company_site"]},
          {"engagement", :engagement, ["freelance_fixed", "full_time"]},
          {"workplace", :workplace, ["remote", "on_site"]},
          {"remote_scope", :remote_scope, ["global", "country_list"]},
          {"status", :status, ["open", "unknown"]}
        ] do
      [one | _] = atoms = Enum.map(values, &String.to_existing_atom/1)

      assert ids(c, %{field => %{"$EQUAL" => hd(values)}}) ==
               direct(where(base(c), [j], field(j, ^column) == ^one)),
             field

      assert ids(c, %{field => %{"$IN" => values}}) ==
               direct(where(base(c), [j], field(j, ^column) in ^atoms)),
             field
    end
  end

  test "origin_kind: what brought a job — an alert's, a Fiverr job's (AQ-12 §11.4)", c do
    alert =
      job_fixture(c.scope,
        title: "From an alert",
        url: "https://www.linkedin.com/jobs/view/555",
        origin: :email,
        origin_kind: :alert
      )

    assert ids(c, %{"origin_kind" => %{"$EQUAL" => "alert"}}) == [alert.id]
    assert ids(c, %{"origin_kind" => %{"$IN" => ["alert", "brief"]}}) == [alert.id]

    assert ids(c, %{"origin_kind" => %{"$IN" => ["inquiry"]}}) ==
             direct(where(base(c), [j], j.origin_kind == :inquiry))

    assert {:error, {:invalid_filter, %{"origin_kind" => _}}} =
             Filters.where(base(c), Jobs, %{"origin_kind" => %{"$EQUAL" => "gig"}}, %{now: @now})
  end

  test "q: the title by substring or trigram, accents ignored, or the company's name", c do
    assert ids(c, %{"q" => %{"$ILIKE" => "CAFE"}}) == [c.jobs.fixed.id]
    assert ids(c, %{"q" => %{"$ILIKE" => "%tuxcare%"}}) == [c.jobs.pounds.id]

    qn = "elixr"
    like = "%elixr%"

    expected =
      direct(
        from(j in base(c),
          left_join: co in assoc(j, :company),
          where:
            fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or
              fragment("? <% lower(unaccent(?))", ^qn, j.title) or
              like(co.name_normalized, ^like) or fragment("? <% ?", ^qn, co.name_normalized)
        )
      )

    assert ids(c, %{"q" => %{"$ILIKE" => "Elixr"}}) == expected
    assert c.jobs.hourly.id in expected
  end

  test "country: listed, or remote worldwide", c do
    expected =
      direct(
        where(
          base(c),
          [j],
          fragment("? = ANY(?)", "PK", j.allowed_countries) or j.remote_scope == :global
        )
      )

    assert ids(c, %{"country" => %{"$EQUAL" => "pk"}}) == expected
    assert expected == Enum.sort([c.jobs.monthly.id, c.jobs.hourly.id])
  end

  test "skills: the job has any of them", c do
    having = from(s in JobSkill, where: s.skill_id in ^[c.go.id], select: s.job_id)

    assert ids(c, %{"skills" => %{"$IN" => [c.go.id]}}) ==
             direct(where(base(c), [j], j.id in subquery(having)))

    assert ids(c, %{"skills" => %{"$IN" => c.go.id}}) == [c.jobs.monthly.id]
  end

  test "money: annualised in one currency; a project only against projects", c do
    money = &%{"$GTE" => %{"min_minor" => &1, "currency" => "usd", "period" => &2}}

    # $4,000 a month is 48,000 a year: the monthly top is 66,000, the hourly 124,800.
    assert ids(c, %{"money" => money.("400000", "month")}) ==
             sorted([c.jobs.monthly, c.jobs.hourly])

    floor = Utils.Units.annualise(600_000, :month)

    assert ids(c, %{"money" => money.(600_000, "month")}) ==
             direct(
               where(
                 base(c),
                 ^dynamic([j], j.comp_currency == "USD" and ^Jobs.annual_top() >= ^floor)
               )
             )

    assert ids(c, %{"money" => money.("100000", "project")}) == [c.jobs.fixed.id]
  end

  test "posted_within: posted_on, else first seen, from now", c do
    live = %{"archived" => %{"$EQUAL" => false}}
    assert ids(c, Map.put(live, "posted_within", %{"$EQUAL" => "1"})) == [c.jobs.monthly.id]

    since = DateTime.add(@now, -7 * 86_400, :second)
    on = DateTime.to_date(since)

    assert ids(c, %{"posted_within" => %{"$EQUAL" => 7}}) ==
             direct(
               where(
                 base(c),
                 [j],
                 (not is_nil(j.posted_on) and j.posted_on >= ^on) or
                   (is_nil(j.posted_on) and j.first_seen_at >= ^since)
               )
             )
  end

  test "archived and has_leads: true and false", c do
    assert ids(c, %{"archived" => %{"$EQUAL" => "true"}}) == [c.jobs.archived.id]
    assert ids(c, %{"archived" => %{"$EQUAL" => false}}) |> length() == 4

    lead_fixture(c.scope, job: c.jobs.monthly, profile: c.golang)
    with_lead = from(l in Lead, where: l.job_id == parent_as(:job).id)

    assert ids(c, %{"has_leads" => %{"$EQUAL" => true}}) ==
             direct(where(base(c), [j], exists(with_lead)))

    assert ids(c, %{"has_leads" => %{"$EQUAL" => "false"}}) ==
             direct(where(base(c), [j], not exists(with_lead)))
  end

  test "not_applied_with: the context's keys, and keys merged into a job", c do
    keys = [c.jobs.monthly.canonical_key, "gone-key"]
    context = %{applied_keys: %{c.golang.id => keys}}
    merged = from(m in Merge, where: m.from_canonical_key in ^keys, select: m.into_job_id)

    assert ids(c, %{"not_applied_with" => %{"$EQUAL" => c.golang.id}}, context) ==
             direct(
               where(base(c), [j], j.canonical_key not in ^keys and j.id not in subquery(merged))
             )

    assert ids(c, %{"not_applied_with" => c.golang.id}, %{applied_keys: %{c.golang.id => []}})
           |> length() == 5

    # A profile the pool didn't check is refused.
    assert {:error, {:invalid_filter, %{"not_applied_with" => _}}} =
             Filters.where(base(c), Jobs, %{"not_applied_with" => Ecto.UUID.generate()}, context)
  end

  test "suggested_for builds nothing: the pool scores in memory, for the profile it checked", c do
    context = %{suggested_for: c.golang.id}
    assert ids(c, %{"suggested_for" => %{"$EQUAL" => c.golang.id}}, context) |> length() == 5

    assert {:error, {:invalid_filter, %{"suggested_for" => _}}} =
             Filters.where(base(c), Jobs, %{"suggested_for" => c.golang.id}, %{})
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"title" => "Go"}, "title"},
          {%{"source" => %{"$NOT_IN" => ["upwork"]}}, "source"},
          {%{"source" => %{"$EQUAL" => "monster"}}, "source"},
          {%{"country" => %{"$EQUAL" => "Pakistan"}}, "country"},
          {%{"skills" => %{"$IN" => ["not-an-id"]}}, "skills"},
          {%{"money" => %{"$GTE" => %{"min_minor" => "1", "currency" => "USD"}}}, "money"},
          {%{
             "money" => %{
               "$GTE" => %{"min_minor" => "-1", "currency" => "USD", "period" => "year"}
             }
           }, "money"},
          {%{"money" => %{"$LT" => %{}}}, "money"},
          {%{"posted_within" => %{"$EQUAL" => "5"}}, "posted_within"},
          {%{"archived" => %{"$EQUAL" => "maybe"}}, "archived"},
          {%{"has_leads" => %{"$IN" => [true]}}, "has_leads"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base(c), Jobs, where, %{now: @now}),
             inspect(where)
    end
  end

  test "money/1 reads all three, or refuses" do
    assert Jobs.money(%{"min_minor" => "5", "currency" => " usd ", "period" => "month"}) ==
             {:ok, %{min: 5, currency: "USD", period: :month}}

    assert Jobs.money(%{"min_minor" => "5", "currency" => "USD", "period" => "fortnight"}) ==
             :error

    assert Jobs.money(%{"min_minor" => "5.5", "currency" => "USD", "period" => "month"}) == :error
  end

  describe "JobsSort" do
    test "one field each, $DESC only, as the keyset pages" do
      assert Filters.order(JobsSort, %{"first_seen_at" => "$DESC"}) ==
               {:ok, [{"first_seen_at", "$DESC"}]}

      assert Filters.order(JobsSort, %{"posted_on" => "$desc"}) == {:ok, [{"posted_on", "$DESC"}]}
      assert Filters.order(JobsSort, %{"money" => "$DESC"}) == {:ok, [{"money", "$DESC"}]}

      assert {:error, {:invalid_filter, %{"posted_on" => _}}} =
               Filters.order(JobsSort, %{"posted_on" => "$ASC"})

      assert {:error, {:invalid_filter, %{"title" => _}}} =
               Filters.order(JobsSort, %{"title" => "$ASC"})
    end

    test "posted sorts unposted last; newest is first seen, descending", c do
      order = JobsSort.build(%{"posted_on" => "$DESC"}) ++ [desc: :id]
      [first | _] = base(c) |> order_by(^order) |> Repo.all()
      assert first.id == c.jobs.monthly.id

      assert [{:desc, _first_seen}] = JobsSort.build(%{"first_seen_at" => "$DESC"})
      assert JobsSort.build(%{"money" => "$DESC"}) == []
    end
  end
end
