defmodule Core.Notifications.Unsubscribe do
  @moduledoc """
  One-click unsubscribe from an email's group (AQ-10B §6, §11.4, QP10b-9),
  **without signing in**: the token in the email (a 60-day `Phoenix.Token`
  of the person and the group, `Data.Notifications.Unsubscribe`) turns
  that group's email switch off. `POST /unsubscribe` at the root answers
  `{group, label}`; an expired, forged or unknown token is 410
  `token_invalid`. RFC 8058's one-click post and the apps' page both land
  here. A locked kind stays on: a group switch never reaches it.
  """

  alias Data.Notifications, as: Store
  alias Data.Notifications.{Preference, Preferences, Unsubscribe}

  @doc "Turns the token's group's email off at `now`. Answers `{:ok, %{group, label}}`."
  @spec run(term(), DateTime.t()) :: {:ok, map()} | {:error, :token_invalid}
  def run(token, %DateTime{} = now) do
    with {:ok, {user_id, group_key}} <- Unsubscribe.verify(token, now),
         %{} = group <- Store.get_group(group_key) || {:error, :token_invalid},
         %{} <- Data.Accounts.get_user(user_id) || {:error, :token_invalid} do
      current = user_id |> Preferences.get(group.key) |> Preference.switches()
      {:ok, _row} = Preferences.put(user_id, group.key, %{current | email: false}, now)
      {:ok, %{group: group.key, label: group.label}}
    end
  end
end
