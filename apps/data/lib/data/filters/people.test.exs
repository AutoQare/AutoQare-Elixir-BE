defmodule Data.Filters.PeopleTest do
  @moduledoc """
  `Data.Filters.People` through `Data.Teams.people/4`: each field against a
  direct query, the base query's reach, and the 422.
  """

  use Data.DataCase, async: true

  alias Data.Accounts.User
  alias Data.Teams

  setup do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    admin = admin_fixture(org)
    fiza = member_fixture(backend, :lead)
    hira = member_fixture(frontend, :member)
    {:ok, _} = Data.Accounts.set_suspended(hira, ~U[2026-11-14 10:00:00.000000Z])

    %{org: org, backend: backend, frontend: frontend, admin: admin, fiza: fiza, hira: hira}
  end

  defp ids(c, team_ids, with_admins?, where) do
    {:ok, users} = Teams.people(c.org.id, team_ids, with_admins?, where)
    users |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp all(c), do: [c.backend.id, c.frontend.id]

  test "the base: the teams' members, and the admins when asked", c do
    assert ids(c, [c.backend.id], false, nil) == [c.fiza.id]
    assert ids(c, all(c), false, nil) == Enum.sort([c.fiza.id, c.hira.id])
    assert ids(c, all(c), true, nil) == Enum.sort([c.admin.id, c.fiza.id, c.hira.id])
  end

  test "q: the name or the email by substring, as a direct query", c do
    hira = Repo.preload(Repo.get!(User, c.hira.id), :person)
    word = String.slice(hira.email, 0, 8)
    like = "%" <> word <> "%"

    expected =
      from(u in User,
        join: p in assoc(u, :person),
        where:
          u.id in ^[c.admin.id, c.fiza.id, c.hira.id] and
            (ilike(p.display_name, ^like) or ilike(u.email, ^like)),
        select: u.id
      )
      |> Repo.all()
      |> Enum.sort()

    assert ids(c, all(c), true, %{"q" => %{"$ILIKE" => "%#{word}%"}}) == expected
    assert c.hira.id in expected
    assert ids(c, all(c), true, %{"q" => %{"$ILIKE" => "%%"}}) |> length() == 3
  end

  test "suspended and admin: true and false", c do
    assert ids(c, all(c), true, %{"suspended" => %{"$EQUAL" => "true"}}) == [c.hira.id]

    assert ids(c, all(c), true, %{"suspended" => %{"$EQUAL" => false}}) ==
             Enum.sort([c.admin.id, c.fiza.id])

    assert ids(c, all(c), true, %{"admin" => %{"$EQUAL" => true}}) == [c.admin.id]
    assert ids(c, all(c), true, %{"admin" => "false"}) == Enum.sort([c.fiza.id, c.hira.id])
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"email" => "x"}, "email"},
          {%{"suspended" => %{"$EQUAL" => "maybe"}}, "suspended"},
          {%{"q" => %{"$EQUAL" => "x"}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Teams.people(c.org.id, all(c), true, where)
    end
  end
end
