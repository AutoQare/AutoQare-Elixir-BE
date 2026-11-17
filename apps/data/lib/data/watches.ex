defmodule Data.Watches do
  @moduledoc """
  Watches (AQ-10 §5, §8). Storage only: who may make one, and what a
  trigger takes, are `Core.Watches`'. A watch is its owner's own, so every
  read but the matcher's is bound to a user.
  """

  import Ecto.Query, warn: false

  alias Data.Behaviour.Watch
  alias Data.Repo

  @preload [:company, contact: :company]

  @doc "A watch of `user_id`; `nil` for anyone else's, or a malformed id."
  @spec get_own(binary(), term()) :: Watch.t() | nil
  def get_own(user_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Watch |> Repo.get_by(id: uuid, user_id: user_id) |> preload()
      :error -> nil
    end
  end

  @doc "The person's watch on `subject` for `trigger`, or `nil`."
  @spec find(binary(), {:company | :contact, binary()}, atom()) :: Watch.t() | nil
  def find(user_id, {kind, id}, trigger) do
    column = if kind == :company, do: :company_id, else: :contact_id

    Watch
    |> where([w], w.user_id == ^user_id and w.trigger == ^trigger)
    |> where([w], field(w, ^column) == ^id)
    |> Repo.one()
    |> preload()
  end

  @doc "The person's watches, newest first (the context puts the expired last)."
  @spec mine(binary()) :: [Watch.t()]
  def mine(user_id) do
    from(w in Watch, where: w.user_id == ^user_id, order_by: [desc: w.inserted_at, desc: w.id])
    |> Repo.all()
    |> preload()
  end

  @doc "The person's watches on one subject."
  @spec mine_on(binary(), {:company | :contact, binary()}) :: [Watch.t()]
  def mine_on(user_id, {kind, id}) do
    column = if kind == :company, do: :company_id, else: :contact_id

    from(w in Watch, where: w.user_id == ^user_id, order_by: [asc: w.inserted_at, asc: w.id])
    |> where([w], field(w, ^column) == ^id)
    |> Repo.all()
    |> preload()
  end

  @doc """
  Every watch on a subject, **locked** for the observation's transaction,
  so two observations at once fire a watch once: the matcher's read.
  """
  @spec on_subject_for_update({:company | :contact, binary()}) :: [Watch.t()]
  def on_subject_for_update({kind, id}) do
    column = if kind == :company, do: :company_id, else: :contact_id

    from(w in Watch, order_by: [asc: w.id], lock: "FOR UPDATE")
    |> where([w], field(w, ^column) == ^id)
    |> Repo.all()
    |> preload()
  end

  @spec create(map()) :: {:ok, Watch.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, watch} <- %Watch{} |> Watch.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, preload(watch)}
  end

  @spec update(Watch.t(), map()) :: {:ok, Watch.t()} | {:error, Ecto.Changeset.t()}
  def update(%Watch{} = watch, attrs) do
    with {:ok, updated} <- watch |> Watch.settings_changeset(attrs) |> Repo.update(),
         do: {:ok, preload(updated)}
  end

  @doc "Marks the watch fired at `at`."
  @spec fired(Watch.t(), DateTime.t()) :: {:ok, Watch.t()}
  def fired(%Watch{} = watch, %DateTime{} = at),
    do: watch |> Watch.fired_changeset(at) |> Repo.update()

  @spec delete(Watch.t()) :: {:ok, Watch.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Watch{} = watch), do: Repo.delete(watch)

  @doc "A contact's watches, whoever's: what *Forget* removes (AQ-10B §5.7 B2)."
  @spec on_contact_for_system(binary()) :: [Watch.t()]
  def on_contact_for_system(contact_id),
    do: Repo.all(from(w in Watch, where: w.contact_id == ^contact_id))

  @doc "Live, unpaused watches expiring between `from` and `until`, every organisation's."
  @spec expiring_for_system(DateTime.t(), DateTime.t()) :: [Watch.t()]
  def expiring_for_system(%DateTime{} = from, %DateTime{} = until) do
    from(w in Watch,
      where:
        not is_nil(w.expires_at) and w.expires_at > ^usec(from) and w.expires_at <= ^usec(until) and
          is_nil(w.paused_at)
    )
    |> Repo.all()
  end

  defp usec(%DateTime{microsecond: {us, _p}} = at), do: %{at | microsecond: {us, 6}}

  defp preload(nil), do: nil
  defp preload(watch_or_list), do: Repo.preload(watch_or_list, @preload)
end
