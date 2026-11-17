defmodule Data.Notifications.Mutes do
  @moduledoc """
  Mutes of a lead or a customer (AQ-10B §11.4, QP10b-3), storage only. A
  second mute of the same subject keeps the first; an unmute of nothing
  is nothing.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.Mute
  alias Data.Repo

  @doc "Mutes `{:lead, id}` or `{:customer, id}` for the person, once."
  @spec mute(binary(), binary(), {:lead | :customer, binary()}, DateTime.t()) :: :ok
  def mute(organisation_id, user_id, {kind, id}, %DateTime{} = now) do
    {target, index} =
      case kind do
        :lead -> {[lead_id: id], :notification_mutes_user_lead_index}
        :customer -> {[customer_id: id], :notification_mutes_user_customer_index}
      end

    row =
      Map.merge(
        %{
          id: Uniq.UUID.uuid7(),
          organisation_id: organisation_id,
          user_id: user_id,
          lead_id: nil,
          customer_id: nil,
          inserted_at: %{now | microsecond: {elem(now.microsecond, 0), 6}}
        },
        Map.new(target)
      )

    {_n, _rows} =
      Repo.insert_all(Mute, [row],
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment,
           if(index == :notification_mutes_user_lead_index,
             do: "(user_id, lead_id) WHERE lead_id IS NOT NULL",
             else: "(user_id, customer_id) WHERE customer_id IS NOT NULL"
           )}
      )

    :ok
  end

  @doc "Unmutes the subject for the person."
  @spec unmute(binary(), {:lead | :customer, binary()}) :: :ok
  def unmute(user_id, {:lead, id}) do
    from(m in Mute, where: m.user_id == ^user_id and m.lead_id == ^id) |> Repo.delete_all()
    :ok
  end

  def unmute(user_id, {:customer, id}) do
    from(m in Mute, where: m.user_id == ^user_id and m.customer_id == ^id) |> Repo.delete_all()
    :ok
  end

  @doc "Whether the person muted the lead, or the customer (either may be `nil`)."
  @spec muted?(binary(), binary() | nil, binary() | nil) :: boolean()
  def muted?(_user_id, nil, nil), do: false

  def muted?(user_id, lead_id, customer_id) do
    query = from(m in Mute, where: m.user_id == ^user_id)

    query =
      case {lead_id, customer_id} do
        {nil, c} -> where(query, [m], m.customer_id == ^c)
        {l, nil} -> where(query, [m], m.lead_id == ^l)
        {l, c} -> where(query, [m], m.lead_id == ^l or m.customer_id == ^c)
      end

    Repo.exists?(query)
  end

  @doc "Of `lead_ids`, the ones the person muted (their customer's mute aside)."
  @spec muted_leads(binary(), [binary()]) :: MapSet.t()
  def muted_leads(_user_id, []), do: MapSet.new()

  def muted_leads(user_id, lead_ids) do
    from(m in Mute, where: m.user_id == ^user_id and m.lead_id in ^lead_ids, select: m.lead_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Of `customer_ids`, the ones the person muted."
  @spec muted_customers(binary(), [binary()]) :: MapSet.t()
  def muted_customers(_user_id, []), do: MapSet.new()

  def muted_customers(user_id, customer_ids) do
    from(m in Mute,
      where: m.user_id == ^user_id and m.customer_id in ^customer_ids,
      select: m.customer_id
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
