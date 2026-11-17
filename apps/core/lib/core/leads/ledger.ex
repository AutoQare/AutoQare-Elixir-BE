defmodule Core.Leads.Ledger do
  @moduledoc """
  A lead's ledger (AQ-04A §5.2, §7, QP4a-5): one `lead_events` row per verb
  that moves or reassigns a lead, written in the verb's transaction, never
  updated.

  - **Who:** `actor_kind` is `customer` from the portal, `extension` for
    staff through the extension (`via: :extension`, AQ-05 §11.4), `user`
    for staff otherwise, `system` with nobody in the scope; a person's id
    rides along. An extension row carries the queued write's `request_id`
    (§10.4) when the verb was given one.
  - **Who reads it** (§7): `saved`, `applied`, `stage_moved`, `state_moved`
    (into and out of On hold), `outcome_set` and `reopened` are the
    customer's too; `owner_changed`, `pipeline_changed`, `cv_set`,
    `archived` and `unarchived` are staff only. P4b (AQ-04B §10):
    `follow_up_logged` is the customer's; `note_added`, `labelled`,
    `follow_up_due` and `archive_warned` are staff only; `task_created` and
    `task_done` follow the task (the customer's when it is shown to them),
    passed as `visibility`. The customer never reads a
    note (`Core.Leads.Sheet` cuts it). AQ-06 §11.6: `conversation_linked`,
    `contact_linked`, `contact_unlinked` and `classified` are staff only;
    the meeting kinds are the customer's; `message_in` and `message_out`
    follow the team's `customer_sees_conversations`, passed as
    `visibility`.
  - **The stage reached** (AQ-11 §7.4, QP11-5): an `applied` or
    `stage_moved` row carries `stage_kind`, the engine kind of the stage
    the lead is at once the verb has moved it (a custom stage's anchor),
    so the funnel reads "reached an interview" from history.
  - **An import** (AQ-12 §11.4, QP12-5): a row an import writes passes
    `actor_kind: :import` and the person it is credited to as
    `actor_user_id` — whoever applied, not whoever ran the import — so the
    dashboards count it as theirs; it moves the activity like a person's.
  - **Activity** (§7, PLAN §6.6): every event made by a person — `user`,
    `customer` or `extension` (a press is a person's act, Q8) — moves the
    lead's `last_activity_at` and its job's, so P4b's sweep reads one
    column. Pin, unpin and edit are audit rows, not events: they move
    nothing.
  """

  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: Store
  alias Data.Leads.{Event, Lead}
  alias Data.Scope

  @staff_only [
    :owner_changed,
    :pipeline_changed,
    :cv_set,
    :archived,
    :unarchived,
    :note_added,
    :labelled,
    :follow_up_due,
    :archive_warned,
    :conversation_linked,
    :contact_linked,
    :contact_unlinked,
    :classified
  ]

  @doc """
  Writes one event of `kind` on `lead` (`attrs`: `from_label`, `to_label`,
  `outcome`, `note`, `document_id`, `task_id`, `note_id`, `is_again`,
  `occurred_at`, `request_id`, and `visibility` where the kind does not decide it; an
  import's `actor_kind: :import` with its `actor_user_id`) and, for a
  person's, moves the activity. Answers the event; raises (rolling the verb
  back) on a row it cannot write.
  """
  @spec record(Scope.t(), Lead.t(), atom(), map(), DateTime.t()) :: Event.t()
  def record(%Scope{} = scope, %Lead{} = lead, kind, attrs, %DateTime{} = now) do
    actor_kind = Map.get(attrs, :actor_kind) || actor_kind(scope)

    {:ok, event} =
      attrs
      |> Map.merge(%{
        organisation_id: lead.organisation_id,
        lead_id: lead.id,
        kind: kind,
        occurred_at: Map.get(attrs, :occurred_at) || now,
        recorded_at: now,
        actor_kind: actor_kind,
        actor_user_id: Map.get(attrs, :actor_user_id) || Scope.user_id(scope),
        visibility:
          Map.get(attrs, :visibility) || if(kind in @staff_only, do: :staff, else: :customer),
        stage_kind: stage_kind(kind, lead)
      })
      |> Store.add_event()

    if actor_kind in [:user, :customer, :extension, :import], do: touch(lead, now)
    event
  end

  @doc "Who made a row, for the scope acting."
  @spec actor_kind(Scope.t()) :: :customer | :extension | :user | :system
  def actor_kind(%Scope{} = scope) do
    cond do
      Scope.customer?(scope) -> :customer
      Scope.user_id(scope) && scope.via == :extension -> :extension
      Scope.user_id(scope) -> :user
      true -> :system
    end
  end

  @doc "The engine kind of a stage: its own, or a custom stage's anchor (AQ-04A §9.2)."
  @spec engine_kind(map() | nil) :: atom() | nil
  def engine_kind(%{kind: :custom, anchor_kind: anchor}), do: anchor
  def engine_kind(%{kind: kind}), do: kind
  def engine_kind(_none), do: nil

  # The stage the verb left the lead at, on the two kinds that reach one.
  defp stage_kind(kind, %Lead{stage: stage}) when kind in [:applied, :stage_moved],
    do: engine_kind(stage)

  defp stage_kind(_kind, _lead), do: nil

  defp touch(lead, now) do
    :ok = Store.touch(lead, now)
    :ok = JobStore.touch(lead.job, now)
  end
end
