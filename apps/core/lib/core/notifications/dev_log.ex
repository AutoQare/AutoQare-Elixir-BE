defmodule Core.Notifications.DevLog do
  @moduledoc """
  Who was told what since a moment (AQ-10B §8, §11.4), for a run's checks
  on a **dev server only** (`GET /team/v1/dev/notifications?since=<iso>`,
  compiled in with `dev_routes`): every notification of the caller's
  organisation written since then, with its person, audience and each
  delivery's state, and the `customer_mail` rows for customers with no
  portal login.
  """

  alias Data.Notifications, as: Store
  alias Data.Notifications.{CustomerMails, Deliveries}
  alias Data.Scope

  @doc "`[{id, kind, to, audience, title, link_path, inserted_at, deliveries}]` then the customer mail."
  @spec since(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def since(%Scope{} = scope, value) do
    with {:ok, since} <- parse(value),
         org when is_binary(org) <- Scope.organisation_id(scope) || {:error, :not_found} do
      rows = Store.since_for_system(org, since)
      customers = rows |> Enum.map(& &1.user_id) |> Enum.uniq() |> Store.customer_users()

      told =
        for n <- rows do
          %{
            id: n.id,
            kind: n.notification_kind_key,
            to: n.user.email,
            audience: audience(n, customers),
            title: n.title,
            link_path: n.link_path,
            inserted_at: n.inserted_at,
            deliveries:
              for d <- Deliveries.for_notification(n.id) do
                %{
                  channel: d.channel,
                  state: d.state,
                  deferred: d.deferred,
                  skip_reason: d.skip_reason,
                  deliver_after: d.deliver_after
                }
              end
          }
        end

      mailed =
        for m <- CustomerMails.since_for_system(org, since) do
          %{kind: m.kind_key, to: m.to_email, audience: "customer_no_login", state: m.state}
        end

      {:ok, told ++ mailed}
    end
  end

  defp audience(n, customers) do
    cond do
      MapSet.member?(customers, n.user_id) -> "customer"
      n.notification_kind.notification_group_key == "system" -> "admin"
      true -> "staff"
    end
  end

  defp parse(nil), do: {:error, {:invalid, %{"since" => ["is required, an ISO 8601 time"]}}}

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _bad -> {:error, {:invalid, %{"since" => ["is an ISO 8601 time"]}}}
    end
  end

  defp parse(_value), do: parse(nil)
end
