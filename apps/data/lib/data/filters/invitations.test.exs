defmodule Data.Filters.InvitationsTest do
  @moduledoc """
  `Data.Filters.Invitations` through `Data.Invitations.list/4`: open and
  past at *now* against a direct query, each column, the search, the 422.
  """

  use Data.DataCase, async: true

  alias Data.Filters
  alias Data.Invitations
  alias Data.Invitations.Invitation

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    backend = team_fixture(org)
    admin = admin_fixture(org)
    scope = scope_for(admin, organisation: org)
    customer = customer_fixture(org, [backend])

    open =
      invite(org,
        team: backend,
        email: "open_one@example.com",
        expires_at: DateTime.add(@now, 3, :day)
      )

    expired =
      invite(org,
        team: backend,
        email: "expired@example.com",
        expires_at: DateTime.add(@now, -1, :day)
      )

    revoked =
      invite(org,
        customer: customer,
        email: "revoked@example.com",
        expires_at: DateTime.add(@now, 3, :day)
      )

    {:ok, revoked} = Invitations.revoke(revoked, @now)

    %{
      org: org,
      backend: backend,
      scope: scope,
      customer: customer,
      open: open,
      expired: expired,
      revoked: revoked
    }
  end

  defp invite(org, attrs), do: invitation_fixture(org, attrs)

  defp ids(c, where) do
    {:ok, rows} = Invitations.list(c.org.id, nil, where, Filters.context(c.scope, now: @now))
    rows |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  test "state: open and past at now, as a direct query", c do
    open =
      direct(
        from(i in Invitation,
          where:
            i.organisation_id == ^c.org.id and is_nil(i.accepted_at) and is_nil(i.revoked_at) and
              i.expires_at > ^@now
        )
      )

    past =
      direct(from(i in Invitation, where: i.organisation_id == ^c.org.id and i.id not in ^open))

    assert open == [c.open.id]
    assert ids(c, %{"state" => %{"$EQUAL" => "open"}}) == open
    assert ids(c, %{"state" => "past"}) == past
    assert past == Enum.sort([c.expired.id, c.revoked.id])
  end

  test "kind, team_id, customer_id: $EQUAL and $IN; q by email", c do
    assert ids(c, %{"kind" => %{"$EQUAL" => "customer"}}) == [c.revoked.id]

    assert ids(c, %{"kind" => %{"$IN" => ["team_member"]}}) ==
             Enum.sort([c.open.id, c.expired.id])

    assert ids(c, %{"team_id" => c.backend.id}) == Enum.sort([c.open.id, c.expired.id])
    assert ids(c, %{"customer_id" => %{"$IN" => [c.customer.id]}}) == [c.revoked.id]
    assert ids(c, %{"q" => %{"$ILIKE" => "%open_one%"}}) == [c.open.id]
    assert ids(c, %{"q" => %{"$ILIKE" => "open_"}}) == [c.open.id]
  end

  test "anything else is refused, naming the field", c do
    for {where, field} <- [
          {%{"state" => %{"$EQUAL" => "later"}}, "state"},
          {%{"state" => %{"$IN" => ["open"]}}, "state"},
          {%{"email" => "x"}, "email"},
          {%{"kind" => "pirate"}, "kind"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} =
               Invitations.list(c.org.id, nil, where, Filters.context(c.scope, now: @now))
    end
  end
end
