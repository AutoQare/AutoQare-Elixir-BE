defmodule Autoqare.ReleaseTest do
  @moduledoc """
  `Autoqare.Release` against the test database (DEPLOY-PLAN L1, D-3, D-9):
  what `bin/autoqare eval` runs on a server, run here inside the sandbox.
  Not async: some tests switch the mailer or D-9's switch for their length.
  """

  use Api.ConnCase, async: false

  import ExUnit.CaptureIO

  alias Autoqare.Release
  alias Data.Organisations

  @org "Regbits BD"
  @admin "super-admin@example.com"

  describe "migrate/0, status/0" do
    test "a migrated database runs nothing: migrate is idempotent" do
      assert Release.migrate() == []
    end

    test "status/0 lists every migration as up" do
      migrations = capture_io(fn -> send(self(), {:status, Release.status()}) end)
      assert_received {:status, list}

      assert list != []
      assert Enum.all?(list, fn {state, _version, _name} -> state == :up end)
      assert migrations =~ "up"
    end
  end

  describe "seed/0" do
    test "is the production seed, and running it twice is safe" do
      out = capture_io(fn -> send(self(), {:seed, Release.seed()}) end)
      assert_received {:seed, results}

      assert out =~ "Production seed: Loaded"
      assert Enum.map(results, &elem(&1, 0)) == Enum.map(Data.Seeds.plan(:prod), & &1.label)

      assert capture_io(fn -> Release.seed() end) =~ "Production seed: Loaded"
      assert Data.Accounts.get_user_by_email(@admin) == nil
    end
  end

  describe "bootstrap/3" do
    test "with SES the invitation is mailed and its link is never printed" do
      out = with_mailer(Swoosh.Adapters.AmazonSES, fn -> bootstrap() end)
      invitation = open_invitation()

      assert out =~ "Created the organisation Regbits BD"
      assert out =~ "Invitation sent to #{@admin}"
      refute out =~ "/invite/"
      refute out =~ invitation.code

      # Run again while it is open: sent again, still no link.
      again = with_mailer(Swoosh.Adapters.AmazonSES, fn -> bootstrap() end)
      assert again =~ "already exists"
      assert again =~ "Invitation sent to #{@admin}"
      refute again =~ invitation.code
      assert open_invitation().id == invitation.id
    end

    test "with local mail, or none, the link is printed, as mix aq.bootstrap does" do
      for adapter <- [Swoosh.Adapters.Local, nil] do
        out = with_mailer(adapter, fn -> bootstrap() end)
        assert out =~ "Accept link: http://localhost:5800/invite/#{open_invitation().code}"
      end
    end

    test "once somebody holds the system admin role it refuses, saying how to hand it on" do
      org = organisation_fixture(%{name: @org, slug: "regbits-bd"})
      _admin = admin_fixture(org, %{email: "dawud@example.com"})

      assert_raise RuntimeError, ~r/already has its system admin/, fn ->
        capture_io(fn -> bootstrap() end)
      end
    end
  end

  describe "seed_standard/0 (D-9)" do
    test "refuses without AQ_ALLOW_TEST_PASSWORDS, and writes nothing" do
      refute Release.test_passwords_allowed?()

      assert_raise RuntimeError, ~r/does not allow test passwords/, fn ->
        Release.seed_standard()
      end

      assert Organisations.the_one() == nil
    end

    test "with the switch, after the bootstrap, it accepts Super Admin's invitation and makes the set" do
      capture_io(fn -> bootstrap() end)

      out =
        with_test_passwords(fn ->
          capture_io(fn -> send(self(), {:standard, Release.seed_standard()}) end)
        end)

      assert_received {:standard, %{made: made}}
      assert "system admin #{@admin}" in made
      assert out =~ "Standard set: made"
      refute out =~ "password123"

      org = Organisations.the_one()
      assert Organisations.the_admin(org.id).user.email == @admin

      assert {:ok, _user} =
               Core.Accounts.sign_in("team-lead1@example.com", "password123", Core.Clock.now())
    end
  end

  defp bootstrap, do: capture_io(fn -> Release.bootstrap(@org, @admin, "Super Admin") end)

  defp open_invitation,
    do: Data.Invitations.open_for(Organisations.the_one().id, :admin, @admin, nil)

  defp with_mailer(adapter, fun) do
    previous = Application.get_env(:notifire, Notifire.Mailer)
    Application.put_env(:notifire, Notifire.Mailer, adapter: adapter)

    try do
      fun.()
    after
      Application.put_env(:notifire, Notifire.Mailer, previous)
    end
  end

  defp with_test_passwords(fun) do
    Application.put_env(:core, :dev_worst_passwords, true)

    try do
      fun.()
    after
      Application.delete_env(:core, :dev_worst_passwords)
    end
  end
end
