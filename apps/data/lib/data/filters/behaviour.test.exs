defmodule Data.Filters.BehaviourTest do
  @moduledoc """
  `Data.Filters.Behaviour`: each field on each part (companies, contacts),
  against a direct query, and the 422s.
  """

  use Data.DataCase, async: true

  alias Data.Behaviour.Watch
  alias Data.Companies.Company
  alias Data.Contacts.Contact
  alias Data.Filters
  alias Data.Watches

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    user = member_fixture(team, :lead)
    scope = scope_for(user, organisation: org)
    corvid = company_fixture(org, name: "Corvid Security")
    bamboo = company_fixture(org, name: "Bamboo Invest")
    mei = contact_fixture(scope, name: "Mei Chen", company: corvid)
    omar = contact_fixture(scope, name: "Omar Haddad")

    {:ok, _watch} =
      Watches.create(%{
        organisation_id: org.id,
        user_id: user.id,
        company_id: corvid.id,
        trigger: :posts_job
      })

    {:ok, _watch} =
      Watches.create(%{
        organisation_id: org.id,
        user_id: user.id,
        contact_id: omar.id,
        trigger: :comes_online
      })

    %{org: org, user: user, corvid: corvid, bamboo: bamboo, mei: mei, omar: omar}
  end

  defp base(c, :company),
    do: from(s in Company, as: :subject, where: s.organisation_id == ^c.org.id)

  defp base(c, :contact),
    do: from(s in Contact, as: :subject, where: s.organisation_id == ^c.org.id)

  defp ids(c, part, where) do
    context = %{part: part, user_id: c.user.id}
    {:ok, query} = Filters.where(base(c, part), Filters.Behaviour, where, context)
    query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  test "q: the name, normalised, by substring, on either part", c do
    assert ids(c, :company, %{"q" => %{"$ILIKE" => "CORVID"}}) ==
             direct(where(base(c, :company), [subject: s], like(s.name_normalized, "%corvid%")))

    assert ids(c, :contact, %{"q" => %{"$ILIKE" => "%mei%"}}) == [c.mei.id]
    assert ids(c, :contact, %{"q" => %{"$ILIKE" => "100%_"}}) == []
  end

  test "kind: the part named answers; the other answers nothing", c do
    assert ids(c, :company, %{"kind" => %{"$EQUAL" => "company"}}) |> length() == 2
    assert ids(c, :contact, %{"kind" => %{"$EQUAL" => "company"}}) == []
    assert ids(c, :contact, %{"kind" => %{"$IN" => ["company", "contact"]}}) |> length() == 2
  end

  test "watched: me, by the part's column", c do
    mine =
      &from(w in Watch,
        where: field(w, ^&1) == parent_as(:subject).id and w.user_id == ^c.user.id
      )

    assert ids(c, :company, %{"watched" => %{"$EQUAL" => "me"}}) ==
             direct(where(base(c, :company), [subject: _s], exists(mine.(:company_id))))

    assert ids(c, :contact, %{"watched" => "me"}) == [c.omar.id]
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"name" => "Mei"}, "name"},
          {%{"kind" => %{"$EQUAL" => "lead"}}, "kind"},
          {%{"watched" => %{"$EQUAL" => c.user.id}}, "watched"},
          {%{"q" => %{"$EQUAL" => "mei"}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Filters.where(base(c, :contact), Filters.Behaviour, where, %{
                 part: :contact,
                 user_id: c.user.id
               })
    end
  end
end
