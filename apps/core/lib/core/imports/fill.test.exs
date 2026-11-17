defmodule Core.Imports.FillTest do
  @moduledoc "`Core.Imports.Fill`: blank fields only, every field with overwrite."

  use ExUnit.Case, async: true

  alias Core.Imports.Fill

  doctest Fill

  @job %{
    company: nil,
    comp_text: "$30/h",
    workplace: nil,
    remote_scope: nil,
    allowed_countries: [],
    job_skills: []
  }

  test "a job: only what is blank, unless overwrite" do
    values = %{
      "company" => "Acme",
      "salary" => "$40/h",
      "worldwide" => true,
      "skill_ids" => ["s1"]
    }

    assert Fill.job(@job, values, false) == [
             {"jobs.company_id", "Acme"},
             {"jobs.workplace", "remote"},
             {"jobs.remote_scope", "global"},
             {"jobs.skills", ["s1"]}
           ]

    assert {"jobs.comp_text", "$40/h"} in Fill.job(@job, values, true)
    assert Fill.job(@job, %{}, true) == []

    assert Fill.words([{"jobs.company_id", "Acme"}, {"jobs.comp_text", "x"}]) ==
             "Fills company, salary."
  end
end
