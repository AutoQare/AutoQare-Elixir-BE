defmodule ApiExt.SiteRoutesTest do
  @moduledoc """
  AQ-12 §11.4 through the router, on a device token: Indeed, YC Work at a
  Startup and Wellfound — each site's document, its lookup, *Save* and *I
  applied*, the page's fields landing in the job, its details table and its
  money and equity; Indeed's account picking the acting profile and its
  mismatch refused; the save-only sites never refused for an identity.
  """

  use ApiExt.ExtCase, async: true

  alias Core.Extension.Configs
  alias Data.JobParts
  alias Data.Jobs, as: JobStore

  @indeed "https://pk.indeed.com/viewjob?jk=4f3c2b1a0d9e8f7a&from=serp"
  @yc_waas "https://www.workatastartup.com/jobs/70123"
  @yc_company "https://www.ycombinator.com/companies/plover-labs/jobs/70123-founding-elixir-engineer"
  @wellfound "https://wellfound.com/jobs/3141592-senior-elixir-engineer"

  @indeed_fields %{
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
      "urgently_hiring" => false,
      "job_type_text" => "Full-time",
      "work_setting_text" => "Remote"
    }
  }

  @yc_fields %{
    "page_kind" => "job",
    "title" => "Founding Elixir Engineer",
    "company_name" => "Plover Labs",
    "location_text" => "Remote (US; Canada)",
    "employment_text" => "Full-time",
    "salary_text" => "$150K - $190K",
    "description_html" => "<p>Own the backend.</p>",
    "yc" => %{
      "batch_text" => "W24",
      "team_size_text" => "12 people",
      "stage_text" => "Seed",
      "experience_text" => "3+ years",
      "visa_text" => "Will sponsor",
      "equity_text" => "0.25% - 1.00%"
    }
  }

  @wellfound_fields %{
    "page_kind" => "job",
    "title" => "Senior Elixir Engineer",
    "company_name" => "Fennec Example",
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

  setup do
    c = board_cast_fixture()

    tanweer_indeed =
      channel_fixture(c.tanweer, kind: :indeed, handle: "Tanweer.Indeed@example.com")

    :ok = Data.Profiles.put_channels(c.golang, [tanweer_indeed.id])
    {device, tokens} = connected(c.fiza)
    Map.merge(c, %{token: tokens.access_token, device: device, tanweer_indeed: tanweer_indeed})
  end

  defp lookup(c, url) do
    body(
      call(c.token, :get, "/v1/jobs/lookup", %{
        "url" => url,
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id
      })
    )
  end

  defp write(c, path, url, fields, extra \\ %{}) do
    call(
      c.token,
      :post,
      path,
      Map.merge(
        %{
          "request_id" => Ecto.UUID.generate(),
          "team_id" => c.backend.id,
          "profile_id" => c.golang.id,
          "url" => url,
          "fields" => fields
        },
        extra
      )
    )
  end

  defp job(c, conn), do: JobStore.get(c.org.id, body(conn)["job"]["id"])

  test "GET /config for each new site: its document as the file holds it", c do
    for site <- ~w(indeed yc_waas wellfound) do
      conn = call(c.token, :get, "/v1/config", %{"site" => site})
      assert conn.status == 200, site
      assert conn.resp_body == File.read!(Path.join(Configs.dir(), site <> ".json"))

      save_only? = Jason.decode!(conn.resp_body)["save_only"] == true
      assert save_only? == site in Data.Vocabulary.ext_save_only_sites()
    end
  end

  describe "Indeed" do
    test "the signed-in account's email picks the acting profile, as LinkedIn's link does", c do
      assert c.tanweer_indeed.identity_key == "indeed:tanweer.indeed@example.com"

      ctx =
        body(
          call(c.token, :get, "/v1/context", %{
            "site" => "indeed",
            "identity" => "tanweer.indeed@example.com"
          })
        )

      assert ctx["identity"]["state"] == "channel"
      assert ctx["identity"]["channel"]["kind"] == "indeed"
      assert ctx["pick"] == %{"profile_id" => c.golang.id, "team_id" => c.backend.id}

      unknown =
        body(
          call(c.token, :get, "/v1/context", %{"site" => "indeed", "identity" => "x@example.com"})
        )

      assert unknown["identity"]["state"] == "unknown" and unknown["pick"] == nil
    end

    test "lookup, save, then the post-apply page's applied: the job, its money and details", c do
      l = lookup(c, @indeed)
      assert {l["key"], l["source"]} == {"indeed:4f3c2b1a0d9e8f7a", "indeed"}
      assert l["can"] == %{"save" => true, "apply" => true, "apply_again" => false}

      saved = write(c, "/v1/leads/save", @indeed, @indeed_fields)
      assert saved.status == 201
      job = job(c, saved)

      assert job.source == :indeed and job.origin == :extension
      assert job.engagement == :full_time and job.workplace == :remote
      assert {job.comp_min_minor, job.comp_max_minor} == {40_000_000, 55_000_000}
      assert {job.comp_currency, job.comp_period} == {"PKR", :month}
      assert job.comp_source == :platform_estimate
      assert job.company.name == "Marten Ledger Example" and is_nil(job.company.website_url)

      assert %Data.Jobs.IndeedDetails{
               is_easily_apply: true,
               is_responsive_employer: true,
               is_urgently_hiring: false,
               work_setting_text: "Remote"
             } = JobParts.get_details(job)

      assert lookup(c, @indeed)["lead"]["answer"] == "saved"

      # The post-apply page: its title, company and place, and the account.
      confirmation = Map.take(@indeed_fields, ~w(title company_name location_text))

      conn =
        write(
          c,
          "/v1/leads/applied",
          @indeed,
          Map.put(confirmation, "page_kind", "confirmation"),
          %{
            "confirmation" => "page_confirmation",
            "applied_via" => "in_platform_easy",
            "identity" => "tanweer.indeed@example.com",
            "from" => %{"state" => "todo", "stage" => nil}
          }
        )

      assert conn.status == 200
      assert body(conn)["answer"] == "applied"
      assert body(conn)["lead"]["state"] == "in_progress"

      lead = Data.Leads.get(c.org.id, body(conn)["lead"]["id"])
      assert lead.applied_confirmation == :page_confirmation
      assert lead.applied_via == :in_platform_easy
    end

    test "I applied from another customer's Indeed: 409 identity_mismatch; Save is allowed", c do
      naveed_indeed = channel_fixture(c.naveed, kind: :indeed, handle: "naveed@example.com")

      conn =
        write(c, "/v1/leads/applied", @indeed, @indeed_fields, %{
          "confirmation" => "by_hand",
          "applied_via" => "in_platform_easy",
          "identity" => "naveed@example.com"
        })

      assert conn.status == 409
      assert code(conn) == "identity_mismatch"

      assert body(conn)["error"]["message"] ==
               "You're signed in as Naveed's Indeed, not Tanweer's. Switch the acting profile, then press again."

      assert body(conn)["error"]["details"]["channel"]["id"] == naveed_indeed.id
      assert lookup(c, @indeed)["lead"]["answer"] == "free"

      saved =
        write(c, "/v1/leads/save", @indeed, @indeed_fields, %{"identity" => "naveed@example.com"})

      assert saved.status == 201
    end
  end

  describe "YC Work at a Startup, save-only" do
    test "both hosts are one posting; save, then I applied by press; the details and equity", c do
      assert lookup(c, @yc_company)["key"] == "yc:70123"

      saved = write(c, "/v1/leads/save", @yc_waas, @yc_fields)
      assert saved.status == 201
      job = job(c, saved)

      assert job.source == :yc_waas

      assert {job.comp_min_minor, job.comp_max_minor, job.comp_period} ==
               {15_000_000, 19_000_000, :year}

      assert {job.equity_min_bp, job.equity_max_bp} == {25, 100}
      assert {job.visa, job.visa_text} == {:yes, "Will sponsor"}
      assert job.workplace == :remote and Enum.sort(job.allowed_countries) == ["CA", "US"]

      assert %Data.Jobs.YcDetails{
               batch: "W24",
               team_size: 12,
               stage_text: "Seed",
               experience_text: "3+ years"
             } = JobParts.get_details(job)

      # The company page's address names the same job.
      assert lookup(c, @yc_company)["lead"]["answer"] == "saved"

      conn =
        write(c, "/v1/leads/applied", @yc_company, @yc_fields, %{
          "confirmation" => "by_hand",
          "applied_via" => "external_ats",
          "from" => %{"state" => "todo", "stage" => nil}
        })

      assert conn.status == 200
      assert body(conn)["answer"] == "applied"
    end
  end

  describe "Wellfound, save-only" do
    test "I applied with no save first: a new lead with the job, its details and ranges", c do
      conn =
        write(c, "/v1/leads/applied", @wellfound, @wellfound_fields, %{
          "confirmation" => "by_hand",
          "applied_via" => "external_ats",
          # A save-only site reads no account: whatever is sent refuses nothing.
          "identity" => "https://www.linkedin.com/in/naveed-example/"
        })

      assert conn.status == 201
      assert body(conn)["lead"]["state"] == "in_progress"
      job = job(c, conn)

      assert job.source == :wellfound and job.workplace == :remote

      assert {job.comp_min_minor, job.comp_max_minor, job.comp_currency} ==
               {14_000_000, 18_000_000, "USD"}

      assert {job.equity_min_bp, job.equity_max_bp} == {10, 50}
      assert {job.visa, job.visa_text} == {:no, "Not available"}

      assert %Data.Jobs.WellfoundDetails{
               company_stage_text: "Series A",
               remote_policy_text: "Remote only",
               timezone_text: "UTC-5 to UTC+3",
               visa_text: "Not available"
             } = JobParts.get_details(job)

      assert lookup(c, @wellfound)["lead"]["answer"] == "refused"
    end
  end
end
