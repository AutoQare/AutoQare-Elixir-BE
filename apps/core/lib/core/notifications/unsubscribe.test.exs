defmodule Core.Notifications.UnsubscribeTest do
  @moduledoc """
  One-click unsubscribe (AQ-10B §11.4, QP10b-9): a token signed for a
  person and a group turns that group's email off for 60 days; expired,
  forged or unknown is `token_invalid`; a locked kind still goes.
  """

  use Core.CoreCase, async: true

  alias Core.Notifications.Unsubscribe
  alias Data.Notifications.Preferences
  alias Data.Notifications.Unsubscribe, as: Token

  @now ~U[2026-11-14 09:00:00.000000Z]

  test "the token's group's email goes off; the answer names the group" do
    user = user_fixture()
    token = Token.sign(user.id, "leads", @now)

    assert Unsubscribe.run(token, @now) == {:ok, %{group: "leads", label: "Leads"}}
    assert %{email: false, push: true} = Preferences.switches(user.id, "leads")
  end

  test "60 days, then gone; a forged token or an unknown group is token_invalid" do
    user = user_fixture()
    token = Token.sign(user.id, "tasks", @now)

    assert {:ok, _} = Unsubscribe.run(token, DateTime.add(@now, 59 * 86_400, :second))

    assert Unsubscribe.run(token, DateTime.add(@now, 61 * 86_400, :second)) ==
             {:error, :token_invalid}

    assert Unsubscribe.run(token <> "x", @now) == {:error, :token_invalid}
    assert Unsubscribe.run(nil, @now) == {:error, :token_invalid}
    assert Unsubscribe.run(Token.sign(user.id, "nope", @now), @now) == {:error, :token_invalid}
  end
end
