defmodule Data.Filters.CustomersTest do
  @moduledoc """
  `Data.Filters.Customers` through `Data.Customers.filtered/4`: each field
  and operator, *mine* against a direct query, and the 422.
  """

  use Data.DataCase, async: true

  alias Data.Customers
  alias Data.Customers.{Customer, Profile, ProfileMember}
  alias Data.Filters

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    fiza = member_fixture(team, :lead)
    scope = scope_for(fiza, organisation: org)

    tanweer = customer_fixture(org, [team], display_name: "Tanweer", email: "tanweer@example.com")

    imran =
      customer_fixture(org, [team], display_name: "Imran Ali", email: "imran_ali@example.com")

    lone = customer_fixture(org, [team], display_name: "Lone 100%", email: "lone@example.com")
    {:ok, imran} = Customers.change_status(imran, :active, ~D[2026-11-14])

    _golang = profile_fixture(tanweer, owners: [fiza])

    %{org: org, team: team, scope: scope, fiza: fiza, tanweer: tanweer, imran: imran, lone: lone}
  end

  defp names(c, where) do
    {:ok, rows} = Customers.filtered(c.org.id, [c.team.id], where, Filters.context(c.scope, []))
    Enum.map(rows, & &1.display_name)
  end

  test "status: $EQUAL and $IN", c do
    assert names(c, %{"status" => %{"$EQUAL" => "active"}}) == ["Imran Ali"]
    assert names(c, %{"status" => "invited"}) == ["Lone 100%", "Tanweer"]
    assert names(c, %{"status" => %{"$IN" => ["active", "invited"]}}) |> length() == 3
  end

  test "q: the name or the email by substring; % and _ are the words themselves", c do
    assert names(c, %{"q" => %{"$ILIKE" => "%TANW%"}}) == ["Tanweer"]
    assert names(c, %{"q" => %{"$ILIKE" => "imran_ali"}}) == ["Imran Ali"]
    assert names(c, %{"q" => %{"$ILIKE" => "i_r"}}) == []
    assert names(c, %{"q" => %{"$ILIKE" => "100%"}}) == ["Lone 100%"]
  end

  test "mine: a customer with a profile the person owns, as a direct query", c do
    owned =
      from(cu in Customer,
        join: p in Profile,
        on: p.customer_id == cu.id,
        join: pm in ProfileMember,
        on: pm.profile_id == p.id,
        where: cu.organisation_id == ^c.org.id and pm.user_id == ^c.fiza.id,
        select: cu.display_name
      )
      |> Repo.all()

    assert names(c, %{"mine" => %{"$EQUAL" => true}}) == owned
    assert owned == ["Tanweer"]
    assert names(c, %{"mine" => %{"$EQUAL" => "false"}}) == ["Imran Ali", "Lone 100%"]
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"team_id" => c.team.id}, "team_id"},
          {%{"status" => %{"$EQUAL" => "pirate"}}, "status"},
          {%{"mine" => %{"$EQUAL" => "maybe"}}, "mine"},
          {%{"q" => %{"$IN" => ["x"]}}, "q"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Customers.filtered(c.org.id, nil, where, Filters.context(c.scope, []))
    end
  end
end
