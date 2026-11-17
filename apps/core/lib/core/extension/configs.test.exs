defmodule Core.Extension.ConfigsTest do
  @moduledoc """
  AQ-05 §11.4's contract 1 (`validate/1`), **the repo's own files against
  it** (§13: whatever `apps/core/priv/extension` holds), and publishing:
  a changed file is a new version, an unchanged one is kept.
  """

  use Core.CoreCase, async: true

  alias Core.Extension.Configs
  alias Data.Extension, as: Store
  alias Data.Extension.Config

  doctest Configs

  @now ~U[2026-11-11 09:00:00.000000Z]

  @valid %{
    "site" => "upwork",
    "contract" => 1,
    "pages" => %{
      "job" => %{"url" => ["/jobs/~0", "re:^/details/~0[0-9a-f]+"], "ready" => ["h4.title"]},
      "proposal" => %{"url" => ["/proposals/"], "ready" => ["form"]}
    },
    "fields" => %{
      "title" => %{"on" => "job", "css" => ["h4.title"], "read" => "text", "required" => true},
      "skills_text" => %{
        "on" => "job",
        "css" => [".skills a"],
        "read" => "text",
        "required" => false,
        "all" => true
      },
      "upwork.client.rating_text" => %{
        "on" => "job",
        "css" => ["[data-test=rating]"],
        "read" => "attr:aria-label",
        "required" => false
      }
    },
    "identity" => %{"css" => ["a[href*='/freelancers/~0']"], "read" => "href"},
    "confirmation" => %{"on" => "proposal", "css" => [".done"], "read" => "present"}
  }

  describe "the repo's files" do
    for site <- Data.Vocabulary.ext_sites() do
      test "#{site}.json, if it is there, keeps contract 1 and names its site" do
        path = Path.join(Configs.dir(), unquote(site) <> ".json")

        if File.exists?(path) do
          assert Configs.check(unquote(site), File.read!(path)) == :ok
        end
      end
    end

    test "the directory holds nothing but the sites' documents" do
      for file <- File.ls!(Configs.dir()) do
        assert Path.rootname(file) in Data.Vocabulary.ext_sites() and
                 Path.extname(file) == ".json",
               "#{file} is not a site's document"
      end
    end
  end

  describe "validate/1" do
    test "a document of contract 1" do
      assert Configs.validate(@valid) == :ok
    end

    test "what is wrong, by its path" do
      doc =
        @valid
        |> put_in(["fields", "salary"], %{
          "on" => "job",
          "css" => ["x"],
          "read" => "text",
          "required" => true
        })
        |> put_in(["fields", "title", "css"], [])
        |> put_in(["fields", "title", "read"], "inner")
        |> put_in(["fields", "skills_text", "on"], "search")
        |> put_in(["pages", "listing"], %{"url" => ["/x"], "ready" => ["y"]})
        |> put_in(["identity", "read"], "html")
        |> put_in(["pages", "job", "url"], ["re:("])
        |> Map.put("contract", 2)
        |> Map.put("extra", true)

      assert {:error, problems} = Configs.validate(doc)

      for expected <- [
            "extra: is not in contract 1",
            "contract: is not 1",
            "pages.listing: is not a page kind",
            "pages.job.url[0]: is not a regular expression",
            "fields.salary: is not a field of §11.3",
            "fields.title.css: has 0, not 1–6",
            "fields.title.read: is not text, href, html, present or attr:<name>",
            "fields.skills_text.on: names no page of this document",
            "identity.read: is not href or text"
          ] do
        assert expected in problems, "#{expected} missing from #{inspect(problems)}"
      end
    end

    test "more than six selectors for a field" do
      doc = put_in(@valid, ["fields", "title", "css"], ~w(a b c d e f g))
      assert {:error, ["fields.title.css: has 7, not 1–6"]} = Configs.validate(doc)
    end

    test "a file that is not JSON, or names another site" do
      assert {:error, ["not JSON: " <> _]} = Configs.check("upwork", "{nope")

      assert {:error, ["site: is not linkedin"]} =
               Configs.check("linkedin", Jason.encode!(@valid))
    end
  end

  describe "AQ-12's contract" do
    @save_only %{
      "site" => "yc_waas",
      "contract" => 1,
      "save_only" => true,
      "pages" => %{"job" => %{"url" => ["re:^/jobs/[^/?#]+"], "ready" => ["main h1"]}},
      "fields" => %{
        "title" => %{"on" => "job", "css" => ["main h1"], "read" => "text", "required" => true},
        "yc.batch_text" => %{
          "on" => "job",
          "css" => [".company-batch"],
          "read" => "text",
          "required" => false
        }
      }
    }

    test "a save-only document may have no identity" do
      assert Configs.validate(@save_only) == :ok
    end

    test "without save_only (or with it false) the identity is required" do
      for doc <- [Map.delete(@save_only, "save_only"), Map.put(@save_only, "save_only", false)] do
        assert {:error, ["identity: is missing"]} = Configs.validate(doc)
      end
    end

    test "save_only is a boolean, and a save-only document's identity is still checked" do
      assert {:error, problems} = Configs.validate(Map.put(@save_only, "save_only", "yes"))
      assert "save_only: is not true or false" in problems

      doc = Map.put(@save_only, "identity", %{"css" => ["x"], "read" => "html"})
      assert {:error, ["identity.read: is not href or text"]} = Configs.validate(doc)
    end

    test "Indeed's identity is read as text" do
      doc = put_in(@valid, ["identity"], %{"css" => [".gnav-email"], "read" => "text"})
      assert Configs.validate(doc) == :ok
    end

    test "a field reads on one page kind or a list of them, each a page of the document" do
      ok = put_in(@valid, ["fields", "title", "on"], ["job", "proposal"])
      assert Configs.validate(ok) == :ok

      wrong =
        @valid
        |> put_in(["fields", "title", "on"], ["job", "search", "nowhere"])
        |> put_in(["fields", "skills_text", "on"], [])

      assert {:error, problems} = Configs.validate(wrong)
      assert "fields.title.on[1]: names no page of this document" in problems
      assert "fields.title.on[2]: is not a page kind" in problems
      assert "fields.skills_text.on: names no page" in problems
    end

    test "the sites' field keys are the contract's" do
      for key <- ~w(indeed.easily_apply indeed.responsive_employer indeed.urgently_hiring
                    indeed.job_type_text indeed.work_setting_text yc.batch_text yc.team_size_text
                    yc.stage_text yc.experience_text yc.visa_text yc.equity_text
                    wellfound.stage_text wellfound.remote_policy_text wellfound.timezone_text
                    wellfound.visa_text wellfound.equity_text) do
        assert key in Configs.field_keys()
      end
    end

    test "the repo's three new documents: Indeed's identity and post-apply page, the save-only two" do
      read = &(Configs.dir() |> Path.join(&1 <> ".json") |> File.read!() |> Jason.decode!())

      indeed = read.("indeed")
      assert indeed["identity"]["read"] == "text"
      assert indeed["confirmation"]["on"] == "confirmation"
      assert indeed["fields"]["title"]["on"] == ["job", "confirmation"]

      assert Enum.any?(
               indeed["pages"]["confirmation"]["url"],
               &String.contains?("/beta/indeedapply/form/post-apply", &1)
             )

      for site <- ~w(yc_waas wellfound) do
        doc = read.(site)
        assert doc["save_only"] == true and not Map.has_key?(doc, "identity")
        assert site in Data.Vocabulary.ext_save_only_sites()
      end

      [workatastartup, companies] = read.("yc_waas")["pages"]["job"]["url"]
      assert Regex.match?(~r/#{String.trim_leading(workatastartup, "re:")}/, "/jobs/12345")

      assert Regex.match?(
               ~r/#{String.trim_leading(companies, "re:")}/,
               "/companies/acme/jobs/AbC12-backend-engineer"
             )
    end
  end

  describe "AQ-12C's contract: match and required_when" do
    test "a field may read by what its line says (match) and be required only when (required_when)" do
      doc =
        @valid
        |> put_in(["fields", "upwork.client.rating_text", "match"], "^rating:?\\s*(.+)$")
        |> put_in(["fields", "skills_text", "match"], "\\bgo\\b")
        |> put_in(["fields", "apply_url"], %{
          "on" => "job",
          "css" => ["a.apply[href]"],
          "read" => "href",
          "required" => false,
          "required_when" => %{"apply_kind" => ["external_ats"]}
        })

      assert Configs.validate(doc) == :ok
    end

    test "a match that doesn't compile, or isn't text, is refused" do
      doc =
        @valid
        |> put_in(["fields", "title", "match"], "(")
        |> put_in(["fields", "skills_text", "match"], 7)

      assert {:error, problems} = Configs.validate(doc)
      assert "fields.title.match: is not a regular expression" in problems
      assert "fields.skills_text.match: is not a regular expression" in problems
    end

    test "required_when names the apply kinds read, on an optional field" do
      field = fn when_, required ->
        %{
          "on" => "job",
          "css" => ["a[href]"],
          "read" => "href",
          "required" => required,
          "required_when" => when_
        }
      end

      for {when_, required, problem} <- [
            {%{"apply_kind" => ["external_ats"]}, true,
             "fields.apply_url.required_when: is for a field not required"},
            {%{"apply_kind" => []}, false,
             "fields.apply_url.required_when.apply_kind: names no apply kind"},
            {%{"apply_kind" => ["by_fax"]}, false,
             "fields.apply_url.required_when.apply_kind[0]: is not an apply kind"},
            {%{"title" => ["x"]}, false,
             "fields.apply_url.required_when.title: is not apply_kind"},
            {%{}, false, "fields.apply_url.required_when: names nothing"},
            {"external_ats", false, "fields.apply_url.required_when: is not an object"}
          ] do
        doc = put_in(@valid, ["fields", "apply_url"], field.(when_, required))
        assert {:error, problems} = Configs.validate(doc)
        assert problem in problems, "#{problem} missing from #{inspect(problems)}"
      end
    end

    test "the repo's LinkedIn and Upwork documents read no line by its position" do
      for site <- ~w(linkedin upwork) do
        doc = Configs.dir() |> Path.join(site <> ".json") |> File.read!() |> Jason.decode!()

        for {key, field} <- doc["fields"], css <- field["css"] do
          refute css =~ ~r/:nth-(child|of-type)\(/, "#{site} #{key}: #{css}"
        end
      end

      linkedin =
        Configs.dir() |> Path.join("linkedin.json") |> File.read!() |> Jason.decode!()

      assert linkedin["fields"]["apply_url"]["required_when"] == %{
               "apply_kind" => ["external_ats"]
             }
    end
  end

  describe "publishing" do
    setup do
      dir = Path.join(System.tmp_dir!(), "aq-ext-config-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, system: Data.Scope.system()}
    end

    test "a changed file is the next version; the same file again is kept", c do
      live = Store.live_config(:upwork)

      body =
        @valid
        |> Map.put(
          "pages",
          Map.put(@valid["pages"], "search", %{
            "url" => ["/s#{System.unique_integer()}"],
            "ready" => ["ul"]
          })
        )
        |> Jason.encode!()

      File.write!(Path.join(c.dir, "upwork.json"), body)

      assert [
               {"linkedin", :missing},
               {"upwork", {:published, version}},
               {"indeed", :missing},
               {"yc_waas", :missing},
               {"wellfound", :missing}
             ] = Configs.publish_files(c.system, c.dir, @now)

      assert version == ((live && live.version) || 0) + 1
      assert Store.live_config(:upwork).sha256 == Config.digest(body)

      assert [_, {"upwork", {:unchanged, ^version}} | _missing] =
               Configs.publish_files(c.system, c.dir, @now)
    end

    test "a file off the contract publishes nothing", c do
      File.write!(Path.join(c.dir, "linkedin.json"), ~s({"site":"linkedin","contract":1}))

      assert [{"linkedin", {:invalid, problems}}, {"upwork", :missing} | _missing] =
               Configs.publish_files(c.system, c.dir, @now)

      assert "pages: is missing" in problems
    end
  end

  describe "reading" do
    setup do
      c = board_cast_fixture()
      Map.merge(c, %{fiza: scope_for(c.fiza), dawud: scope_for(c.dawud)})
    end

    test "the live document is the highest version", c do
      config = config_fixture(:linkedin)
      assert {:ok, %{version: version, sha256: sha}} = Configs.live(c.fiza, "linkedin")
      assert {version, sha} == {config.version, config.sha256}
    end

    test "a site off the list is a field error", c do
      assert {:error, {:invalid, %{"site" => _}}} = Configs.live(c.fiza, "monster")
      assert {:error, {:invalid, %{"site" => _}}} = Configs.live(c.fiza, nil)
    end

    test "the versions list is the system admin's, newest first", c do
      older = config_fixture(:upwork, published_at: ~U[2026-11-01 09:00:00.000000Z])
      newer = config_fixture(:upwork, published_at: ~U[2026-11-10 09:00:00.000000Z])

      upwork = %{"$where" => %{"site" => %{"$EQUAL" => "upwork"}}}
      assert {:ok, [first, second | _]} = Configs.list(c.dawud, upwork)
      assert {first.id, second.id} == {newer.id, older.id}
      assert Configs.list(c.fiza, upwork) == {:error, :not_found}

      assert {:error, {:invalid_filter, %{"site" => _}}} =
               Configs.list(c.dawud, %{"$where" => %{"site" => %{"$EQUAL" => "monster"}}})
    end
  end
end
