defmodule Core.Imports.FieldsTest do
  @moduledoc "`Core.Imports.Fields`: the fields per kind and the guess from headers."

  use ExUnit.Case, async: true

  alias Core.Imports.Fields

  doctest Fields

  test "the kinds' fields, as §11.4 lists them" do
    assert "applied_by" in Fields.for_kind("applications")
    refute "applied_by" in Fields.for_kind("jobs")
    refute "date" in Fields.for_kind(:jobs)
    assert Fields.for_kind("contacts") == ~w(name title company email linkedin phone notes ignore)

    assert %{key: "date", label: "Date applied", required: true} in Fields.view("applications")
    assert %{key: "name", label: "Name", required: true} in Fields.view("contacts")
  end

  test "the aliases, and a header nobody names" do
    assert Fields.guess("applications", "URL") == "job_url"
    assert Fields.guess("applications", "Link") == "job_url"
    assert Fields.guess("applications", "BD") == "applied_by"
    assert Fields.guess("applications", "Salary") == "salary"
    assert Fields.guess("applications", "WORLDWIDE") == "worldwide"
    assert Fields.guess("jobs", "Applied By") == "ignore"
    assert Fields.guess("applications", "Favourite colour") == "ignore"
    refute Fields.known?("jobs", "status")
    assert Fields.known?("applications", "status")
  end
end
