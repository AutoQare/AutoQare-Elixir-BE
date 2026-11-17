defmodule Data.Notifications.LeadWatchers do
  @moduledoc """
  *Watch* on a lead (AQ-10B §11.4, QP10b-15), storage only: one row per
  lead and person; a second watch keeps the first.
  """

  import Ecto.Query, warn: false

  alias Data.Repo

  @doc "The person watches the lead (once)."
  @spec watch(binary(), binary(), DateTime.t()) :: :ok
  def watch(lead_id, user_id, %DateTime{} = now) do
    {_n, _rows} =
      Repo.insert_all(
        "lead_watchers",
        [
          %{
            lead_id: Ecto.UUID.dump!(lead_id),
            user_id: Ecto.UUID.dump!(user_id),
            inserted_at: %{now | microsecond: {elem(now.microsecond, 0), 6}}
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:lead_id, :user_id]
      )

    :ok
  end

  @doc "The person stops watching the lead."
  @spec unwatch(binary(), binary()) :: :ok
  def unwatch(lead_id, user_id) do
    from(w in "lead_watchers",
      where: w.lead_id == type(^lead_id, :binary_id) and w.user_id == type(^user_id, :binary_id)
    )
    |> Repo.delete_all()

    :ok
  end

  @doc "The lead's watchers' user ids."
  @spec watchers(binary()) :: [binary()]
  def watchers(lead_id) do
    from(w in "lead_watchers",
      where: w.lead_id == type(^lead_id, :binary_id),
      order_by: w.inserted_at,
      select: type(w.user_id, :binary_id)
    )
    |> Repo.all()
  end

  @doc "For each of `lead_ids`, `%{lead_id => {watchers_count, watching?}}` for `user_id`."
  @spec summary([binary()], binary() | nil) :: %{binary() => {non_neg_integer(), boolean()}}
  def summary([], _user_id), do: %{}

  def summary(lead_ids, user_id) do
    rows =
      from(w in "lead_watchers",
        where: w.lead_id in type(^lead_ids, {:array, :binary_id}),
        select: {type(w.lead_id, :binary_id), type(w.user_id, :binary_id)}
      )
      |> Repo.all()

    rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {lead_id, users} -> {lead_id, {length(users), user_id in users}} end)
  end
end
