defmodule Core.Leads.History do
  @moduledoc """
  The lead page's History (AQ-04B §8.1): `GET /leads/:id/history?$where&before`,
  the ledger newest first, a keyset page of `event`s. `$where` is
  `Data.Filters.History`'s (`kind {$IN: [lead_event_kinds]}`; the chips:
  *Moves*, *Notes*, *Tasks*, *Follow-ups*, *System* are the client's
  groupings of them); `before` is the id of the last event seen. Whoever on the staff reads the lead reads
  its History; the customer reads theirs in the portal's sheet (its
  customer-visible rows, without reasons), so here a customer finds nothing.
  """

  alias Core.Leads
  alias Core.Leads.Sheet
  alias Data.Leads, as: Store
  alias Data.Scope

  @page 50

  @doc "A page: `{items: [event], next_cursor}` (`next_cursor` the id to send as `before`, or nil)."
  @spec page(Scope.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, lead_id, params) do
    params = Leads.stringify(params)

    with :ok <- if(Scope.customer?(scope), do: {:error, :not_found}, else: :ok),
         {:ok, lead} <- Leads.fetch(scope, :read, lead_id),
         {:ok, before} <- before(lead, params["before"]),
         {:ok, events} <- Store.history(lead.id, params["$where"], before: before, limit: @page) do
      {page, more} = Enum.split(events, @page)

      {:ok,
       %{
         items: Enum.map(page, &Sheet.event/1),
         next_cursor: if(more == [], do: nil, else: List.last(page).id)
       }}
    end
  end

  defp before(_lead, nil), do: {:ok, nil}
  defp before(_lead, ""), do: {:ok, nil}

  defp before(lead, id) do
    case Store.event(lead.id, id) do
      nil -> Leads.invalid("before", "is not an event of this lead")
      event -> {:ok, event}
    end
  end
end
