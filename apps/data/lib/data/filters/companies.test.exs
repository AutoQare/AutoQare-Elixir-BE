defmodule Data.Filters.CompaniesTest do
  @moduledoc "`Data.Filters.Companies`: the search against a direct query, and the 422s."

  use Data.DataCase, async: true

  alias Data.Companies.Company
  alias Data.Filters

  setup do
    org = organisation_fixture()

    for name <- ["Bamboo Invest", "Bambú Labs", "TuxCare", "Fennec Cloud"],
        do: company_fixture(org, name: name)

    %{org: org}
  end

  defp base(c), do: from(x in Company, where: x.organisation_id == ^c.org.id)

  defp names(c, where) do
    {:ok, query} = Filters.where(base(c), Filters.Companies, where)
    query |> Repo.all() |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "q: the normalised name by substring or trigram, as a direct query finds it", c do
    for words <- ["bamb", "BAMBU", "%care%", "Fenec Cloud"] do
      qn = Company.normalize(String.trim(words, "%"))
      like = "%" <> qn <> "%"

      expected =
        base(c)
        |> where([x], like(x.name_normalized, ^like) or fragment("? % ?", x.name_normalized, ^qn))
        |> Repo.all()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names(c, %{"q" => %{"$ILIKE" => words}}) == expected, words
    end

    assert names(c, %{"q" => %{"$ILIKE" => "BAMBU"}}) == ["Bambú Labs"]
    assert length(names(c, %{"q" => %{"$ILIKE" => ""}})) == 4
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"name" => "TuxCare"}, "name"},
          {%{"q" => %{"$EQUAL" => "tux"}}, "q"},
          {%{"q" => %{"$ILIKE" => ["tux"]}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Filters.where(base(c), Filters.Companies, where)
    end
  end
end
