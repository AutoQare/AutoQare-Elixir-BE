defmodule Data.Notifications.CustomerMails do
  @moduledoc """
  Mail for customers with no portal login (AQ-10B §11.4, QP10b-2), storage
  only. `core` writes a row once per `dedupe_key`; `notifire`'s sweep takes
  the `pending` ones under `FOR UPDATE SKIP LOCKED` and records what became
  of each.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.CustomerMail
  alias Data.Repo

  @doc """
  Writes the mail unless its `dedupe_key` exists. Answers `{:ok, row}`
  with `:new` or `:there`.
  """
  @spec ensure(map(), DateTime.t()) :: {:new | :there, CustomerMail.t()}
  def ensure(attrs, %DateTime{} = now) do
    now = usec(now)

    row =
      Map.merge(
        %{
          id: Uniq.UUID.uuid7(),
          state: :pending,
          attempts: 0,
          html: nil,
          ics: nil,
          inserted_at: now,
          updated_at: now
        },
        Map.take(attrs, [
          :organisation_id,
          :customer_id,
          :kind_key,
          :dedupe_key,
          :to_email,
          :subject,
          :text,
          :ics
        ])
      )

    {n, _rows} =
      Repo.insert_all(CustomerMail, [row], on_conflict: :nothing, conflict_target: [:dedupe_key])

    there = Repo.get_by!(CustomerMail, dedupe_key: attrs.dedupe_key)
    {if(n == 1, do: :new, else: :there), there}
  end

  @doc "The oldest `pending` row nobody else holds, locked for the calling transaction."
  @spec next_pending_for_system() :: CustomerMail.t() | nil
  def next_pending_for_system do
    from(m in CustomerMail,
      where: m.state == :pending,
      order_by: [asc: m.inserted_at, asc: m.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.one()
  end

  @doc "Sent, with what was sent."
  @spec mark_sent(CustomerMail.t(), String.t(), String.t(), DateTime.t()) :: :ok
  def mark_sent(%CustomerMail{id: id}, html, text, %DateTime{} = now) do
    from(m in CustomerMail, where: m.id == ^id)
    |> Repo.update_all(
      set: [
        state: :sent,
        html: html,
        text: text,
        sent_at: usec(now),
        error: nil,
        updated_at: usec(now)
      ]
    )

    :ok
  end

  @doc "Skipped (the customer has a login by now, or no address)."
  @spec mark_skipped(CustomerMail.t(), DateTime.t()) :: :ok
  def mark_skipped(%CustomerMail{id: id}, %DateTime{} = now) do
    from(m in CustomerMail, where: m.id == ^id)
    |> Repo.update_all(set: [state: :skipped, updated_at: usec(now)])

    :ok
  end

  @doc "A failed attempt; the `max`th makes it `failed`. Answers the state it is in."
  @spec record_failure(CustomerMail.t(), String.t(), DateTime.t(), pos_integer()) ::
          :pending | :failed
  def record_failure(%CustomerMail{id: id, attempts: attempts}, error, %DateTime{} = now, max) do
    attempts = attempts + 1
    state = if attempts >= max, do: :failed, else: :pending

    from(m in CustomerMail, where: m.id == ^id)
    |> Repo.update_all(
      set: [
        state: state,
        attempts: attempts,
        error: String.slice(error, 0, 500),
        updated_at: usec(now)
      ]
    )

    state
  end

  @doc "An organisation's rows written since `since`, oldest first: the dev route's checks."
  @spec since_for_system(binary(), DateTime.t()) :: [CustomerMail.t()]
  def since_for_system(organisation_id, %DateTime{} = since) do
    since = usec(since)

    from(m in CustomerMail,
      where: m.organisation_id == ^organisation_id and m.inserted_at >= ^since,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc "A customer's rows, oldest first: what a test or a run asks."
  @spec for_customer(binary()) :: [CustomerMail.t()]
  def for_customer(customer_id) do
    from(m in CustomerMail, where: m.customer_id == ^customer_id, order_by: [asc: m.inserted_at])
    |> Repo.all()
  end

  defp usec(%DateTime{microsecond: {us, _p}} = at), do: %{at | microsecond: {us, 6}}
end
