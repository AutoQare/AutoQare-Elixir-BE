defmodule Core.Ingest.Extension.SitesTest do
  @moduledoc """
  AQ-12 §11.4, PLAN §5.6: Indeed's, YC's and Wellfound's readings, pure —
  and the whole capture of each site through `Normalize.run/2`, as the
  extension's mock pages send it.
  """

  use ExUnit.Case, async: true

  alias Core.Ingest.Extension.{Normalize, Sites}

  doctest Sites
  doctest Core.Ingest.Extension.Pool

  @now ~U[2026-11-15 09:00:00Z]
  @opts %{now: @now, zone: "Asia/Karachi", skills: []}

  # As the extension's adapters read the mock pages (AQ-12 §11.4).
  @indeed %{
    "captured_at" => "2026-11-15T09:00:00.000Z",
    "page_kind" => "job",
    "title" => "Go Backend Engineer, Ledger",
    "company_name" => "Marten Ledger Example",
    "company_url" => "https://www.indeed.com/cmp/Marten-Ledger-Example",
    "location_text" => "Remote in Karachi, Sindh",
    "salary_text" => "Rs 400,000 - Rs 550,000 a month",
    "employment_text" => "Full-time",
    "apply_kind" => "in_platform_easy",
    "description_html" => "<p>Build the ledger service in Go.</p>",
    "indeed" => %{
      "easily_apply" => true,
      "responsive_employer" => true,
      "urgently_hiring" => true,
      "job_type_text" => "Full-time",
      "work_setting_text" => "Remote"
    }
  }

  @yc %{
    "page_kind" => "job",
    "title" => "Founding Elixir Engineer",
    "company_name" => "Plover Labs",
    "company_url" => "https://www.workatastartup.com/companies/plover-labs",
    "location_text" => "Remote (US; Canada)",
    "employment_text" => "Full-time",
    "salary_text" => "$150K - $190K",
    "skills_text" => ["Elixir", "Phoenix", "PostgreSQL"],
    "description_html" => "<p>Own the backend.</p>",
    "yc" => %{
      "batch_text" => "W24",
      "team_size_text" => "12 people",
      "stage_text" => "Seed",
      "experience_text" => "3+ years",
      "visa_text" => "US citizenship/visa not required",
      "equity_text" => "0.25% - 1.00%"
    }
  }

  @wellfound %{
    "page_kind" => "job",
    "title" => "Senior Elixir Engineer",
    "company_name" => "Fennec Example",
    "company_url" => "https://wellfound.com/company/fennec-example",
    "salary_text" => "$140k – $180k",
    "employment_text" => "Full Time",
    "description_html" => "<p>Build the platform.</p>",
    "wellfound" => %{
      "stage_text" => "Series A",
      "remote_policy_text" => "Remote only",
      "timezone_text" => "UTC-5 to UTC+3",
      "visa_text" => "Not available",
      "equity_text" => "0.1% – 0.5%"
    }
  }

  describe "Indeed" do
    test "the whole capture: pay as an estimate with its period, the setting, the flags" do
      norm = Normalize.run(@indeed, Map.put(@opts, :site, :indeed))

      assert norm.job["title"] == "Go Backend Engineer, Ledger"
      assert norm.job["engagement"] == "full_time"
      assert norm.job["workplace"] == "remote"
      assert norm.job["apply_method"] == "in_platform_easy"

      assert Map.take(norm.job, ~w(comp_min_minor comp_max_minor comp_currency comp_period
                                   comp_source comp_text)) == %{
               "comp_min_minor" => 40_000_000,
               "comp_max_minor" => 55_000_000,
               "comp_currency" => "PKR",
               "comp_period" => "month",
               "comp_source" => "platform_estimate",
               "comp_text" => "Rs 400,000 - Rs 550,000 a month"
             }

      assert norm.details == %{
               is_easily_apply: true,
               is_responsive_employer: true,
               is_urgently_hiring: true,
               work_setting_text: "Remote"
             }

      # Indeed's own company page is no website.
      assert norm.company == %{"name" => "Marten Ledger Example"}
    end

    test "each period Indeed writes" do
      for {text, period, min} <- [
            {"$50,000 - $70,000 a year", "year", 5_000_000},
            {"₹30,000 a month", "month", 3_000_000},
            {"$25 an hour", "hour", 2500},
            {"From $1,200 a week", "week", 120_000}
          ] do
        money = Sites.money(:indeed, %{"salary_text" => text})
        assert money["comp_period"] == period, text
        assert money["comp_min_minor"] == min, text
        assert money["comp_source"] == "platform_estimate"
      end

      assert Sites.money(:indeed, %{"salary_text" => "Competitive"}) == %{}
      assert Sites.money(:indeed, %{}) == %{}
    end

    test "the description wins over the remote tag (PLAN §5.6)" do
      on_site =
        @indeed
        |> Map.put("description_html", "<p>This role is on-site at our Lahore office.</p>")
        |> Normalize.run(Map.put(@opts, :site, :indeed))

      assert on_site.job["workplace"] == "on_site"
      assert on_site.job["onsite_locations"] == ["Karachi, Sindh"]

      hybrid =
        @indeed
        |> Map.put("description_html", "<p>Hybrid: two days a week in the office.</p>")
        |> Normalize.run(Map.put(@opts, :site, :indeed))

      assert hybrid.job["workplace"] == "hybrid"

      # A description that says nothing of the place leaves the tag.
      in_person =
        @indeed
        |> put_in(["indeed", "work_setting_text"], "In person")
        |> Normalize.run(Map.put(@opts, :site, :indeed))

      assert in_person.job["workplace"] == "on_site"
    end

    test "without Easily apply on the page, the apply kind says it; the job type stands in" do
      fields =
        @indeed
        |> Map.delete("employment_text")
        |> Map.put("indeed", %{"job_type_text" => "Part-time"})

      norm = Normalize.run(fields, Map.put(@opts, :site, :indeed))
      assert norm.job["engagement"] == "part_time"
      assert norm.details == %{is_easily_apply: true}
    end
  end

  describe "YC Work at a Startup" do
    test "the whole capture: salary a year, equity in basis points, the details" do
      norm = Normalize.run(@yc, Map.put(@opts, :site, :yc_waas))

      assert norm.job["comp_min_minor"] == 15_000_000 and norm.job["comp_max_minor"] == 19_000_000
      assert norm.job["comp_period"] == "year" and norm.job["comp_source"] == "parsed_text"
      assert norm.job["equity_min_bp"] == 25 and norm.job["equity_max_bp"] == 100
      assert norm.job["visa_text"] == "US citizenship/visa not required"
      refute Map.has_key?(norm.job, "visa")
      assert norm.job["workplace"] == "remote"
      assert norm.job["remote_scope"] == "country_list"
      assert Enum.sort(norm.job["allowed_countries"]) == ["CA", "US"]

      assert norm.details == %{
               batch: "W24",
               team_size: 12,
               stage_text: "Seed",
               experience_text: "3+ years"
             }

      assert norm.company == %{"name" => "Plover Labs"}
      assert norm.unmatched_skills == ["Elixir", "Phoenix", "PostgreSQL"]
    end

    test "a batch however YC writes it; a team size; a visa where it is plain" do
      assert Sites.batch("W24") == "W24"
      assert Sites.batch("YC S23") == "S23"
      assert Sites.batch("Winter 2025") == "W25"
      assert Sites.batch("Fall '24") == "F24"
      assert Sites.batch("Seed") == nil
      assert Sites.team_size("Team size: 25") == 25
      assert Sites.team_size("small") == nil
      assert Sites.visa("Will sponsor") == "yes"
      assert Sites.visa("US citizen/visa only") == "existing_auth_only"
      assert Sites.visa("We do not sponsor visas") == "no"
    end
  end

  describe "Wellfound" do
    test "the whole capture: salary, equity, the remote policy, the details" do
      norm = Normalize.run(@wellfound, Map.put(@opts, :site, :wellfound))

      assert norm.job["comp_min_minor"] == 14_000_000 and norm.job["comp_max_minor"] == 18_000_000
      assert norm.job["comp_currency"] == "USD" and norm.job["comp_period"] == "year"
      assert norm.job["equity_min_bp"] == 10 and norm.job["equity_max_bp"] == 50
      assert norm.job["engagement"] == "full_time"
      assert norm.job["workplace"] == "remote"
      assert norm.job["visa"] == "no" and norm.job["visa_text"] == "Not available"

      assert norm.details == %{
               company_stage_text: "Series A",
               remote_policy_text: "Remote only",
               timezone_text: "UTC-5 to UTC+3",
               visa_text: "Not available"
             }

      assert norm.company == %{"name" => "Fennec Example"}
    end

    test "a compensation line holding both: the money half and the equity half" do
      fields =
        @wellfound
        |> Map.put("salary_text", "$120k – $160k • 0.5% – 1.0%")
        |> update_in(["wellfound"], &Map.delete(&1, "equity_text"))

      norm = Normalize.run(fields, Map.put(@opts, :site, :wellfound))

      assert norm.job["comp_min_minor"] == 12_000_000 and norm.job["comp_max_minor"] == 16_000_000
      assert norm.job["comp_text"] == "$120k – $160k • 0.5% – 1.0%"
      assert norm.job["equity_min_bp"] == 50 and norm.job["equity_max_bp"] == 100
    end

    test "equity over 100% or with no percentage is nothing" do
      assert Sites.equity("150%") == %{}
      assert Sites.equity("Equity available") == %{}
      assert Sites.equity("1% - 0.5%") == %{"equity_min_bp" => 50, "equity_max_bp" => 100}
    end
  end

  test "another site's link reads the shared fields alone" do
    norm =
      @wellfound
      |> Map.put("salary_text", "$140k – $180k a year")
      |> Normalize.run(Map.put(@opts, :site, :other))

    assert norm.job["comp_source"] == "parsed_text"
    refute Map.has_key?(norm.job, "equity_min_bp")
    assert norm.details == %{}
    assert Sites.details(:other, @wellfound, nil) == %{}
  end
end
