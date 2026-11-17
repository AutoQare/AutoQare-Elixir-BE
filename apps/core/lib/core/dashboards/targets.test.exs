defmodule Core.Dashboards.TargetsTest do
  @moduledoc """
  AQ-11 P11.1: a member's target from their profiles, then overridden
  (`PATCH /teams/:id/members/:user_id`), then given back; working days
  only, an organisation setting.
  """

  use Core.CoreCase, async: true

  alias Core.Dashboards
  alias Core.Dashboards.Targets
  alias Core.Organisation.Teams

  doctest Core.Dashboards.Targets

  # Thursday 12 Nov 2026 and Saturday 14 Nov 2026, noon in Karachi.
  @thursday ~U[2026-11-12 07:00:00.000000Z]
  @saturday ~U[2026-11-14 07:00:00.000000Z]

  test "in two teams, one overridden: its override plus the profiles only the other serves" do
    assert Targets.person(
             [%{team_id: "a", daily_target: 30}, %{team_id: "b", daily_target: nil}],
             [
               %{profile_id: "p", daily_target: 35, team_ids: ["a"]},
               %{profile_id: "q", daily_target: 15, team_ids: ["b"]}
             ]
           ) == 45

    assert Targets.person([], []) == nil
  end

  describe "through the team and My numbers" do
    setup do
      c = board_cast_fixture()

      _second =
        profile_fixture(c.naveed, title: "Rust backend", owners: [c.fiza], daily_target: 10)

      _paused = profile_fixture(c.naveed, title: "Paused", owners: [c.fiza], status: :paused)
      c
    end

    defp target(c, user, team, now) do
      {:ok, members} = Teams.list_members(scope_for(c.hira), team.id, now)
      Enum.find(members, &(&1.user_id == user.id))
    end

    test "the profiles' sum, then the override, then the sum again", c do
      hs = scope_for(c.hira)
      {:ok, me} = Dashboards.me(scope_for(c.fiza), %{}, @thursday)
      # Golang 35 + Rust 10; the paused profile carries none.
      assert me.target.today == 45
      assert %{daily_target: nil, target_today: 45} = target(c, c.fiza, c.backend, @thursday)
      # Frontend serves neither profile.
      assert %{target_today: nil} = target(c, c.fiza, c.frontend, @thursday)

      {:ok, member} =
        Teams.update_member(hs, c.backend.id, c.fiza.id, %{"daily_target" => 20}, @thursday)

      assert %{daily_target: 20, target_today: 20} = member
      assert {:ok, %{target: %{today: 20}}} = Dashboards.me(scope_for(c.fiza), %{}, @thursday)

      {:ok, back} =
        Teams.update_member(hs, c.backend.id, c.fiza.id, %{"daily_target" => nil}, @thursday)

      assert %{daily_target: nil, target_today: 45} = back

      assert [%{action: "target_changed"}, %{action: "target_changed"}] =
               Data.Repo.all(Data.Audit.AuditEvent)
               |> Enum.filter(&(&1.action == "target_changed"))
    end

    test "a team's leads and the system admin set it; staff may not; a number from 0", c do
      bs = scope_for(c.bilal)

      assert {:ok, %{daily_target: 0}} =
               Teams.update_member(bs, c.backend.id, c.qasim.id, %{daily_target: 0}, @thursday)

      assert {:ok, _} =
               Teams.update_member(
                 scope_for(c.dawud),
                 c.backend.id,
                 c.qasim.id,
                 %{daily_target: 30},
                 @thursday
               )

      assert {:error, {:forbidden, _words}} =
               Teams.update_member(
                 scope_for(c.fiza),
                 c.backend.id,
                 c.qasim.id,
                 %{daily_target: 9},
                 @thursday
               )

      assert {:error, :not_found} =
               Teams.update_member(bs, c.frontend.id, c.fiza.id, %{daily_target: 9}, @thursday)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Teams.update_member(bs, c.backend.id, c.qasim.id, %{daily_target: -1}, @thursday)

      assert %{daily_target: [_]} = errors_on(changeset)

      assert {:error, {:missing, [:daily_target]}} =
               Teams.update_member(bs, c.backend.id, c.qasim.id, %{}, @thursday)
    end

    test "a day off has no target; the organisation chooses its working days", c do
      fs = scope_for(c.fiza)
      {:ok, saturday} = Dashboards.me(fs, %{}, @saturday)
      assert saturday.target.today == nil

      assert Enum.map(saturday.target.run, & &1.on) ==
               Enum.to_list(Date.range(~D[2026-11-09], ~D[2026-11-13]))

      assert %{target_today: nil} = target(c, c.fiza, c.backend, @saturday)

      {:ok, _} =
        Core.Organisation.update_settings(scope_for(c.dawud), %{
          "working_days" => [6, 1, 2, 3, 4, 5]
        })

      assert {:ok, %{target: %{today: 45}}} = Dashboards.me(fs, %{}, @saturday)
      assert %{target_today: 45} = target(c, c.fiza, c.backend, @saturday)
    end
  end
end
