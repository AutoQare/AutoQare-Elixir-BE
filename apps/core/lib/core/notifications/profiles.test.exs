defmodule Core.Notifications.ProfilesTest do
  @moduledoc """
  AQ-10B §5.7 CP1–CP3 through the customer verbs: staff change a profile
  and the customer is told; the customer changes a channel and the owners
  are told; the owners change, or the customer joins a team, and the new
  owners and the team's leads are told. Never the actor.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Customers.{Channels, Profiles}
  alias Data.Notifications.Notification

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    board_cast_fixture()
  end

  defp rows(user_id, kind) do
    from(n in Notification, where: n.user_id == ^user_id and n.notification_kind_key == ^kind)
    |> Repo.all()
  end

  test "staff change the customer's profile: the customer is told (in-app and digest)", c do
    {:ok, _} =
      Profiles.update(scope_for(c.hira), c.golang.id, %{"headline" => "Senior Go engineer"})

    assert [%{title: "Your team updated the profile “Golang backend”"}] =
             rows(c.tanweer.user_id, "profiles.updated_by_team")
  end

  test "the customer adds a channel: the owners are told, not the customer", c do
    {:ok, _} =
      Channels.create(
        customer_scope_for(c.tanweer),
        c.tanweer.id,
        %{
          "kind" => "linkedin",
          "handle" => "https://linkedin.com/in/tanweer-x",
          "label" => "LinkedIn"
        },
        @now
      )

    for owner <- [c.fiza, c.qasim] do
      assert [%{title: "Tanweer changed a channel (added): LinkedIn"}] =
               rows(owner.id, "profiles.updated_by_customer")
    end

    assert rows(c.tanweer.user_id, "profiles.updated_by_customer") == []
  end

  test "owners changed: the new owner and the team's leads told; the customer moved into a team: its leads",
       c do
    {:ok, _} =
      Profiles.put_owners(scope_for(c.hira), c.golang.id, [c.fiza.id, c.muaz.id], @now)

    assert [%{title: "Hira made you an owner of Tanweer · Golang backend"}] =
             rows(c.muaz.id, "profiles.owners_changed")

    assert [%{title: "Hira changed who looks after Tanweer · Golang backend"}] =
             rows(c.bilal.id, "profiles.owners_changed")

    assert rows(c.hira.id, "profiles.owners_changed") == []

    {:ok, _} = Core.Customers.assign_team(scope_for(c.dawud), c.tanweer.id, c.frontend.id, @now)

    assert "Dawud moved Tanweer into Frontend squad" in Enum.map(
             rows(c.hira.id, "profiles.owners_changed"),
             & &1.title
           )
  end
end
