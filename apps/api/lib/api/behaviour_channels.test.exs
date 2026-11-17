defmodule Api.BehaviourChannelsTest do
  @moduledoc """
  AQ-10 §10, §11.4 over real channels, after commit and ids only:
  `observation_added {kind, id}` on `team:` for each team that touches the
  subject; a watch that fires tells its watcher (`notification_created`
  on `user:`); a team that doesn't touch the subject hears nothing.
  """

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian
  alias Core.Behaviour

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    corvid = company_fixture(c.org, name: "Corvid Security")
    _job = job_fixture(scope_for(c.qasim), team: c.backend, company: corvid)
    Map.put(c, :corvid, corvid)
  end

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  test "team: hears observation_added; the watcher hears notification_created", c do
    {:ok, _, _} =
      subscribe_and_join(socket_for(c.qasim), Api.TeamChannel, "team:" <> c.backend.id)

    {:ok, _, _} =
      subscribe_and_join(socket_for(c.hira), Api.TeamChannel, "team:" <> c.frontend.id)

    {:ok, _, _} = subscribe_and_join(socket_for(c.fiza), Api.UserChannel, "user:" <> c.fiza.id)

    {:ok, {:created, _watch}} =
      Core.Watches.create(
        scope_for(c.fiza),
        %{"company_id" => c.corvid.id, "trigger" => "any_activity"},
        @now
      )

    {:ok, o} =
      Behaviour.observe(scope_for(c.qasim), %{
        company_id: c.corvid.id,
        kind: :seen_online,
        source: :manual,
        observed_at: @now,
        active_at: @now
      })

    id = c.corvid.id
    assert_push "observation_added", %{kind: "company", id: ^id}
    assert_push "notification_created", %{id: _notification}
    refute_push "observation_added", %{kind: "company", id: _other}

    assert o.kind == :seen_online
  end
end
