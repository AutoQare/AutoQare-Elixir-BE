defmodule Data.Notifications.Unsubscribe do
  @moduledoc """
  The one-click unsubscribe token (AQ-10B §11.4, QP10b-9): a signed
  `Phoenix.Token` of `{user_id, group_key}`, valid **60 days**, with no
  table behind it. `notifire` signs it into every notification email's
  footer and `List-Unsubscribe` header; `core` verifies it at `POST
  /unsubscribe`. Here, in `data`, because both reach `data` and neither
  reaches the other. The key is the endpoint's `secret_key_base`, read
  from config.
  """

  @salt "aq unsubscribe v1"
  @max_age 60 * 86_400

  @doc "How long a token works, in seconds."
  def max_age, do: @max_age

  @doc "A token for this person and group, signed at `now`."
  @spec sign(binary(), String.t(), DateTime.t()) :: String.t()
  def sign(user_id, group_key, %DateTime{} = now) do
    Phoenix.Token.sign(secret(), @salt, %{
      "u" => user_id,
      "g" => group_key,
      "t" => DateTime.to_unix(now)
    })
  end

  @doc "The person and group a token names, if it was signed here within 60 days of `now`."
  @spec verify(term(), DateTime.t()) :: {:ok, {binary(), String.t()}} | {:error, :token_invalid}
  def verify(token, %DateTime{} = now) when is_binary(token) do
    # `Phoenix.Token` would compare with the system clock; the signing time
    # rides in the payload, so the dev clock a run moves holds too.
    case Phoenix.Token.verify(secret(), @salt, token, max_age: :infinity) do
      {:ok, %{"u" => user_id, "g" => group, "t" => at}}
      when is_binary(user_id) and is_binary(group) and is_integer(at) ->
        if DateTime.to_unix(now) - at <= @max_age,
          do: {:ok, {user_id, group}},
          else: {:error, :token_invalid}

      _forged_or_unreadable ->
        {:error, :token_invalid}
    end
  end

  def verify(_token, _now), do: {:error, :token_invalid}

  defp secret do
    :api
    |> Application.get_env(Api.Endpoint, [])
    |> Keyword.get(:secret_key_base) ||
      raise "config :api, Api.Endpoint has no secret_key_base"
  end
end
