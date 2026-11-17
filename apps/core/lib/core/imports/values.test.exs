defmodule Core.Imports.ValuesTest do
  @moduledoc "`Core.Imports.Values`: a row's cells read through the mapping, pure."

  use ExUnit.Case, async: true

  alias Core.Imports.Values

  @ctx %{
    kind: "applications",
    date_order: :day_month,
    today: ~D[2026-11-15],
    mapping: %{
      "Date" => "date",
      "Link" => "job_url",
      "By" => "applied_by",
      "Profile" => "profile",
      "Stack" => "stack",
      "Remote" => "worldwide",
      "Country" => "country",
      "Status" => "status"
    },
    members: [%{id: "u-fiza", name: "Fiza Malik", email: "fiza@example.com"}],
    profiles: [
      %{id: "p-go", title: "Golang backend", customer_name: "Tanweer"},
      %{id: "p-rust", title: "Rust", customer_name: "Naveed"}
    ],
    skills: [%{id: "s-go", name: "Go"}, %{id: "s-node", name: "Node.js"}],
    tab: %{profile_id: "p-go", applier_user_id: nil}
  }

  defp read(cells, ctx \\ @ctx), do: Values.read(ctx, cells)
  defp codes(reasons), do: Enum.map(reasons, & &1["code"])

  test "a good row: the key, the profile by \"Customer · Title\", the person by email, skills by alias" do
    {values, reasons} =
      read(%{
        "Date" => "10/9/2026",
        "Link" => "https://www.linkedin.com/jobs/view/42?trk=x",
        "By" => "FIZA@example.com",
        "Profile" => "Naveed · Rust",
        "Stack" => "golang, nodejs",
        "Remote" => "Yes",
        "Country" => "United States"
      })

    assert reasons == []
    assert values["date"] == "2026-09-10"
    assert values["key"] == "linkedin:42"
    assert values["profile_id"] == "p-rust"
    assert values["applier_user_id"] == "u-fiza"
    assert values["skill_ids"] == ["s-go", "s-node"]
    assert values["worldwide"] == true
    assert values["countries"] == ["US"]
  end

  test "the errors and the warnings" do
    {_values, reasons} =
      read(%{
        "Date" => "31/02/2024",
        "Link" => "not a link",
        "By" => "Fizza",
        "Status" => "Ghosted"
      })

    assert codes(reasons) == ~w(bad_link bad_date unknown_person unknown_status)

    assert Enum.find(reasons, &(&1["code"] == "unknown_person"))["words"] ==
             "Unknown name “Fizza”. Fiza?"

    assert codes(Values.errors(reasons)) == ~w(bad_link bad_date unknown_person)

    {_values, reasons} =
      read(%{"Date" => "01/01/2024", "Link" => "https://x.example/j/1", "By" => "direct"})

    assert codes(reasons) == ~w(unknown_person)

    {_values, reasons} =
      read(%{
        "Date" => "01/01/2024",
        "Link" => "https://x.example/j/1",
        "By" => "Fiza",
        "Profile" => "Python"
      })

    assert codes(reasons) == ~w(no_profile)
  end

  test "a Fiverr link is a job list's only" do
    cells = %{
      "Link" => "https://www.fiverr.com/briefs/123",
      "Date" => "01/01/2024",
      "By" => "Fiza"
    }

    {_values, reasons} = read(cells)
    assert "bad_link" in codes(reasons)

    {values, reasons} = read(cells, %{@ctx | kind: "jobs"})
    assert reasons == [] and values["fiverr"] == true and is_nil(values["key"])
  end
end
