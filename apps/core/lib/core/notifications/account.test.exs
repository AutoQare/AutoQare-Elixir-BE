defmodule Core.Notifications.AccountTest do
  @moduledoc """
  AQ-10B §5.1 and §5.7's account events through their verbs: security
  (locked, to the person whoever acted, email at once), the welcome at the
  first sign-in, invitations accepted and expired, teams and roles, the
  extension connected and disconnected. Never the actor, except security.
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Accounts
  alias Core.Notifications.Scans
  alias Core.Organisation.Invitations
  alias Core.Organisation.Teams
  alias Data.Notifications.{Deliveries, Notification}

  @now ~U[2026-11-14 06:00:00.000000Z]

  setup do
    board_cast_fixture()
  end

  defp told(user, kind) do
    for n <- Repo.all(Notification), n.user_id == user.id, n.notification_kind_key == kind, do: n
  end

  describe "security (locked)" do
    test "a changed password tells the person, by email at once, past a group switched off", c do
      preference_fixture(c.fiza, "account", %{email: false})
      fiza = Data.Accounts.get_user(c.fiza.id)

      assert :ok =
               Accounts.change_password(
                 scope_for(fiza),
                 valid_password(),
                 "another long secret 42"
               )

      assert [%{title: "Your password was changed", link_path: "/account"} = n] =
               told(c.fiza, "account.security")

      assert [%{channel: :email, deferred: false}] = Deliveries.for_notification(n.id)
    end

    test "signed out everywhere, suspended and restored are each told", c do
      :ok = Accounts.logout_all(scope_for(c.fiza))
      {:ok, _} = Accounts.suspend(scope_for(c.dawud), c.qasim.id, @now)
      {:ok, _} = Accounts.unsuspend(scope_for(c.dawud), c.qasim.id)

      assert [%{title: "You were signed out on every device"}] = told(c.fiza, "account.security")

      assert ["Your account was restored", "Your account was suspended"] =
               c.qasim |> told("account.security") |> Enum.map(& &1.title) |> Enum.sort()

      assert told(c.dawud, "account.security") == []
    end
  end

  describe "welcome" do
    test "the first sign-in welcomes the person once", c do
      user = user_fixture(email: "new.person@example.com")
      member_fixture(c.backend, :member, user)

      {:ok, _} = Accounts.sign_in("new.person@example.com", valid_password(), @now)
      {:ok, _} = Accounts.sign_in("new.person@example.com", valid_password(), @now)

      assert [%{title: "Welcome to AutoQare", body: "Connect the Chrome extension" <> _}] =
               told(user, "account.welcome")
    end
  end

  describe "invitations" do
    test "accepted: the inviter told, the new person welcomed; for a customer also the leads and owners",
         c do
      staff =
        invitation_fixture(c.org,
          team: c.backend,
          email: "nadia@example.com",
          invited_by_user_id: c.hira.id
        )

      {:ok, %{user: nadia}} =
        Invitations.accept(
          staff.code,
          %{"name" => "Nadia", "password" => "a long secret 2026"},
          now: @now
        )

      assert [%{title: "Nadia accepted your invitation to Backend squad"}] =
               told(c.hira, "account.invitation_accepted")

      assert [_welcome] = told(nadia, "account.welcome")

      # Hira added Nadia herself by accepting: no team notice to Nadia.
      assert told(nadia, "account.team_changed") == []

      _sara_cv = profile_fixture(c.sara, title: "Sara's CV", owners: [c.qasim])

      sara =
        invitation_fixture(c.org, customer: c.sara, invited_by_user_id: c.fiza.id)

      {:ok, _} =
        Invitations.accept(
          sara.code,
          %{"name" => "Sara", "password" => "a long secret 2026"},
          now: @now
        )

      for person <- [c.fiza, c.hira, c.bilal, c.qasim] do
        titles = person |> told("account.invitation_accepted") |> Enum.map(& &1.title)
        assert "Sara joined the portal" in titles, person.id
      end

      assert told(c.muaz, "account.invitation_accepted") == []
    end

    test "an invitation expiring unused tells its inviter once (the hourly scan)", c do
      inv =
        invitation_fixture(c.org,
          team: c.backend,
          invited_by_user_id: c.hira.id,
          expires_at: DateTime.add(@now, -3600, :second)
        )

      for _twice <- 1..2, do: Scans.invitations(@now)

      assert [%{title: "Your invitation to " <> rest}] =
               told(c.hira, "account.invitation_expired")

      assert rest =~ inv.email
    end
  end

  describe "teams" do
    test "a role changed and a removal tell the person, never the actor", c do
      {:ok, _} =
        Teams.change_role(scope_for(c.dawud), c.backend.id, c.fiza.id, "lead")

      :ok =
        Teams.remove_member(scope_for(c.dawud), c.backend.id, c.qasim.id, @now)

      assert [%{title: "Dawud made you a team lead of Backend squad"}] =
               told(c.fiza, "account.team_changed")

      assert [%{title: "Dawud removed you from Backend squad"}] =
               told(c.qasim, "account.team_changed")

      assert told(c.dawud, "account.team_changed") == []
    end
  end

  describe "the extension" do
    test "connected tells the person (locked); disconnected by someone else tells them, by themselves not",
         c do
      {:ok, %{code: code}} = Core.Extension.connect_code(scope_for(c.fiza), @now)

      {:ok, %{device: device}} =
        Core.Extension.connect(code, %{"extension_version" => "1.0.0"}, %{agent: "Chrome"}, @now)

      assert [%{title: "The extension connected to your account"}] =
               told(c.fiza, "account.extension_connected")

      {:ok, _} = Core.Extension.disconnect(scope_for(c.dawud), device.id, @now)

      assert [%{title: "Dawud disconnected your extension"}] =
               told(c.fiza, "account.extension_off")

      {:ok, %{code: mine}} = Core.Extension.connect_code(scope_for(c.qasim), @now)

      {:ok, %{device: own}} =
        Core.Extension.connect(mine, %{"extension_version" => "1.0.0"}, %{}, @now)

      {:ok, _} = Core.Extension.disconnect(scope_for(c.qasim), own.id, @now)
      assert told(c.qasim, "account.extension_off") == []
    end
  end
end
