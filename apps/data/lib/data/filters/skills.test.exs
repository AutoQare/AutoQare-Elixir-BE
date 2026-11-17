defmodule Data.Filters.SkillsTest do
  @moduledoc "`Data.Filters.Skills`: `q` and `category` against a direct query, and the 422s."

  use Data.DataCase, async: true

  alias Data.Customers.Skill
  alias Data.Filters

  setup do
    org = organisation_fixture()
    elixir = skill_fixture(org, name: "Elixir", category: "languages")
    go = skill_fixture(org, name: "Go", category: "languages")
    phoenix = skill_fixture(org, name: "Phoenix", category: "frameworks")
    %{org: org, elixir: elixir, go: go, phoenix: phoenix}
  end

  defp base(c), do: from(s in Skill, where: s.organisation_id == ^c.org.id)

  defp ids(c, where) do
    {:ok, query} = Filters.where(base(c), Filters.Skills, where)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  test "q: the name by substring, case-insensitive", c do
    assert ids(c, %{"q" => %{"$ILIKE" => "ELI"}}) ==
             direct(where(base(c), [s], ilike(s.name, "%ELI%")))

    assert ids(c, %{"q" => %{"$ILIKE" => "%o%"}}) == Enum.sort([c.go.id, c.phoenix.id])
  end

  test "category: $EQUAL and $IN", c do
    assert ids(c, %{"category" => %{"$EQUAL" => "languages"}}) ==
             direct(where(base(c), [s], s.category == "languages"))

    assert ids(c, %{"category" => %{"$IN" => ["languages", "frameworks"]}}) |> length() == 3
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"slug" => "go"}, "slug"},
          {%{"category" => %{"$ILIKE" => "lang"}}, "category"},
          {%{"q" => %{"$EQUAL" => "go"}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Filters.where(base(c), Filters.Skills, where)
    end
  end
end
