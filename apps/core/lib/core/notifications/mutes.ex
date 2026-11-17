defmodule Core.Notifications.Mutes do
  @moduledoc """
  Muting a lead or a customer's whole pipeline (AQ-10B §6, §11.4,
  QP10b-3), staff only, each person their own. **A muted subject writes no
  notification row at all** for that person (`silenced?/1`, asked by the
  seam before it writes): the lead, or every lead, task, approval and
  meeting of the muted customer — except `tasks.mentioned`,
  `approvals.requested` and `meetings.reminder`, which still reach them.

  `POST /leads/:id/mute` · `DELETE` and `POST /customers/:id/mute` ·
  `DELETE` (team): anyone who can read the subject may mute it; 204. A
  customer gets `not_found`.
  """

  import Ecto.Query, warn: false

  alias Core.Customers
  alias Core.Leads
  alias Data.Notifications.{Mute, Mutes}
  alias Data.Repo
  alias Data.Scope

  @always ~w(tasks.mentioned approvals.requested meetings.reminder)

  @doc "`POST /leads/:id/mute` (`on?` true) or `DELETE` (false): `:ok`."
  @spec lead(Scope.t(), term(), boolean(), DateTime.t()) :: :ok | {:error, term()}
  def lead(%Scope{} = scope, id, on?, %DateTime{} = now) do
    with :ok <- staff(scope),
         {:ok, lead} <- Leads.fetch(scope, :read, id) do
      set(scope, {:lead, lead.id}, on?, now)
    end
  end

  @doc "`POST /customers/:id/mute` (`on?` true) or `DELETE` (false): `:ok`."
  @spec customer(Scope.t(), term(), boolean(), DateTime.t()) :: :ok | {:error, term()}
  def customer(%Scope{} = scope, id, on?, %DateTime{} = now) do
    with :ok <- staff(scope),
         {:ok, customer} <- Customers.get(scope, id) do
      set(scope, {:customer, customer.id}, on?, now)
    end
  end

  defp set(scope, subject, true, now),
    do: Mutes.mute(Scope.organisation_id(scope), Scope.user_id(scope), subject, now)

  defp set(scope, subject, false, _now), do: Mutes.unmute(Scope.user_id(scope), subject)

  defp staff(scope) do
    if not Scope.customer?(scope) and Scope.user_id(scope), do: :ok, else: {:error, :not_found}
  end

  @doc "Whether the scope's person muted this lead (the sheet's `muted`)."
  @spec lead_muted?(Scope.t(), binary()) :: boolean()
  def lead_muted?(%Scope{} = scope, lead_id) do
    case Scope.user_id(scope) do
      nil -> false
      me -> MapSet.member?(Mutes.muted_leads(me, [lead_id]), lead_id)
    end
  end

  @doc "The customers with `muted` set for the scope's person (staff); untouched for a customer."
  @spec mark_customers(Scope.t(), [struct()]) :: [struct()]
  def mark_customers(%Scope{} = scope, customers) do
    if not Scope.customer?(scope) and Scope.user_id(scope) do
      muted = Mutes.muted_customers(Scope.user_id(scope), Enum.map(customers, & &1.id))
      Enum.map(customers, &%{&1 | muted: MapSet.member?(muted, &1.id)})
    else
      customers
    end
  end

  @doc """
  Whether a notification about to be written (`attrs`, as the seam takes
  them) is silenced by its recipient's mute of its lead or its customer.
  One query for a person with no mutes at all.
  """
  @spec silenced?(map()) :: boolean()
  def silenced?(%{notification_kind_key: kind}) when kind in @always, do: false

  def silenced?(%{user_id: user_id} = attrs) when is_binary(user_id) do
    if Repo.exists?(from(m in Mute, where: m.user_id == ^user_id)) do
      {lead_id, customer_id} = subject(attrs)
      Mutes.muted?(user_id, lead_id, customer_id)
    else
      false
    end
  end

  def silenced?(_attrs), do: false

  # The row's lead and its customer: from the lead, the task or the approval.
  defp subject(%{lead_id: lead_id}) when is_binary(lead_id) do
    customer =
      from(l in Data.Leads.Lead,
        join: p in assoc(l, :profile),
        where: l.id == ^lead_id,
        select: p.customer_id
      )
      |> Repo.one()

    {lead_id, customer}
  end

  defp subject(%{task_id: task_id}) when is_binary(task_id) do
    {nil, Repo.one(from(t in Data.Tasks.Task, where: t.id == ^task_id, select: t.customer_id))}
  end

  defp subject(%{approval_id: approval_id}) when is_binary(approval_id) do
    from(a in Data.Approvals.Approval,
      where: a.id == ^approval_id,
      select: {a.lead_id, a.customer_id}
    )
    |> Repo.one()
    |> Kernel.||({nil, nil})
  end

  defp subject(_attrs), do: {nil, nil}
end
