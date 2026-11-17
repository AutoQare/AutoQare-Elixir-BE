defmodule Data.Filters.ContactsTest do
  @moduledoc """
  `Data.Filters.Contacts`: each field and operator, and the search against
  a direct query.
  """

  use Data.DataCase, async: true

  alias Data.Contacts.{Contact, Handle}
  alias Data.Filters

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    scope = scope_for(member_fixture(team, :lead), organisation: org)
    acme = company_fixture(org, name: "Acme")
    juniper = company_fixture(org, name: "Juniper Edge")

    mei =
      contact_fixture(scope,
        name: "Mei Chen",
        company: juniper,
        handles: [{:email, "mei@juniper.io"}]
      )

    omar = contact_fixture(scope, name: "Omar Haddad", company: acme)
    zed = contact_fixture(scope, name: "Zed Nobody")
    %{org: org, acme: acme, juniper: juniper, mei: mei, omar: omar, zed: zed}
  end

  defp ids(c, where) do
    base = from(x in Contact, where: x.organisation_id == ^c.org.id)
    {:ok, query} = Filters.where(base, Filters.Contacts, where)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  test "company_id: $EQUAL, $IN, $NULL, $NOT_NULL", c do
    assert ids(c, %{"company_id" => %{"$EQUAL" => c.acme.id}}) == [c.omar.id]
    assert ids(c, %{"company_id" => c.acme.id}) == [c.omar.id]

    assert ids(c, %{"company_id" => %{"$IN" => [c.acme.id, c.juniper.id]}}) ==
             Enum.sort([c.omar.id, c.mei.id])

    assert ids(c, %{"company_id" => %{"$NULL" => true}}) == [c.zed.id]
    assert ids(c, %{"company_id" => %{"$NOT_NULL" => true}}) == Enum.sort([c.omar.id, c.mei.id])
  end

  test "q: a name by substring or trigram, or a handle, as a direct query finds them", c do
    for words <- ["mei", "%CHEN%", "Juniper", "haddad", "nobody"] do
      qn = Contact.normalize(String.trim(words, "%"))
      like = "%" <> qn <> "%"
      handles = from(h in Handle, where: like(h.value_normalized, ^like), select: h.contact_id)

      expected =
        direct(
          from(x in Contact,
            where:
              x.organisation_id == ^c.org.id and
                (like(x.name_normalized, ^like) or fragment("? % ?", x.name_normalized, ^qn) or
                   x.id in subquery(handles))
          )
        )

      assert ids(c, %{"q" => %{"$ILIKE" => words}}) == expected, words
    end

    assert ids(c, %{"q" => %{"$ILIKE" => "mei@juniper"}}) == [c.mei.id]
    assert ids(c, %{"q" => %{"$ILIKE" => "%%"}}) |> length() == 3
  end

  test "anything else is refused, naming the field", c do
    base = from(x in Contact, where: x.organisation_id == ^c.org.id)

    for {where, field} <- [
          {%{"name" => "Mei"}, "name"},
          {%{"q" => %{"$EQUAL" => "mei"}}, "q"},
          {%{"company_id" => %{"$GT" => c.acme.id}}, "company_id"},
          {%{"company_id" => "not-an-id"}, "company_id"},
          {%{"q" => %{"$ILIKE" => 12}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => [_words]}}} =
               Filters.where(base, Filters.Contacts, where)
    end
  end
end
