defmodule Data.Seeds.Notifications do
  @moduledoc """
  The notification groups and kinds (AQ-02 §8, §11): reference data, loaded
  in **every environment, test included**, idempotent by key. A later
  phase adds its group here as rows, not as a migration. **Kinds are
  reference data owned by code**, so a load updates a kind or group that
  exists in place (`Data.Notifications.upsert_kind/1`): a changed default
  reaches a database seeded before the change. People's switches are their
  own rows, untouched.

  P2 brought `tasks`; P4a and P4b `leads`; P6 `conversations` and
  `meetings`; P7 `approvals`; P8 corrected every kind to PLAN §11 and
  added `account`; P9 the forwarding code and proposed meetings; P10
  `behaviour`.

  **P10b (AQ-10B §5, §11.4, QP10b-1, QP10b-4)** splits each kind's channels
  by audience — `default_channels` the staff's, `customer_channels` the
  customer's (`nil` when the same, `[]` when the kind is not for them) —
  applies §5's Δ rows, adds 35 kinds and the groups `profiles` (after
  approvals) and `system` (the system admin's, last before account), and
  locks the security kinds (`account.security`,
  `account.extension_connected`), which can't be switched off and pass
  quiet hours and snooze. `account` becomes a group people can switch off;
  the bell stays always on. 68 kinds in nine groups.

  Two things are code and not columns: each kind's **label** (`label/1`,
  what settings and delivery health show) and its **offered** channels
  (`offered/2`): shown as a switch, off until the person turns it on (§5's
  ○).
  """

  alias Data.Notifications

  @groups [
    %{key: "tasks", label: "Tasks", position: 0, can_disable: true},
    %{key: "leads", label: "Leads", position: 1, can_disable: true},
    %{key: "conversations", label: "Conversations", position: 2, can_disable: true},
    %{key: "meetings", label: "Meetings", position: 3, can_disable: true},
    %{key: "approvals", label: "Approvals", position: 4, can_disable: true},
    %{key: "profiles", label: "Profiles", position: 5, can_disable: true},
    %{key: "behaviour", label: "Behaviour", position: 6, can_disable: true},
    %{key: "system", label: "System", position: 7, can_disable: true},
    %{key: "account", label: "Account", position: 8, can_disable: true}
  ]

  # `{key, label, staff, staff offered, customer, customer offered, options}`,
  # AQ-10B §5 row by row as §11.4 pins it. `customer: :same` is the staff's
  # list; `[]` is "not for this audience". Options: `:passes` (quiet
  # hours), `:locked`.
  @kinds [
    # ── Tasks (§5.2) ──
    {"tasks.assigned", "Task assigned", ~w(inapp push), ~w(email extension), ~w(inapp push email),
     [], []},
    {"tasks.customer_created", "Customer added a task", ~w(inapp push extension), [], [], [], []},
    {"tasks.commented", "Task comment", ~w(inapp push), ~w(extension), ~w(inapp push email), [],
     []},
    {"tasks.mentioned", "Mentioned on a task", ~w(inapp push extension), ~w(email), [], [], []},
    {"tasks.completed", "Task done", ~w(inapp), [], ~w(inapp push), [], []},
    {"tasks.due_soon", "Task due soon", ~w(inapp digest), [], :same, [], []},
    {"tasks.overdue", "Task overdue", ~w(inapp push digest), [], ~w(inapp push email digest), [],
     []},
    {"tasks.nudged", "Nudged on a step", ~w(inapp push), ~w(extension), ~w(inapp push email), [],
     []},
    {"tasks.step_done", "Step done by someone else", ~w(inapp push), [], [], [], []},
    {"tasks.customer_changed", "Customer changed a task", ~w(inapp digest), [], [], [], []},
    {"tasks.removed", "Task archived or deleted", ~w(inapp), [], [], [], []},
    # ── Leads and jobs (§5.3) ──
    {"leads.assigned", "Lead handed to you", ~w(inapp push), ~w(extension), [], [], []},
    {"leads.taken", "Lead handed on", ~w(inapp), [], [], [], []},
    {"leads.moved", "Lead moved", ~w(inapp), [], [], [], []},
    {"leads.applied_again", "Applied again", ~w(inapp digest), [], [], [], []},
    {"leads.customer_update", "Application update", [], [], ~w(inapp digest), [], []},
    {"leads.customer_milestone", "Your search moved forward", [], [], ~w(inapp push email), [],
     []},
    {"leads.milestone_team", "Interview, offer or hire", ~w(inapp push), [], [], [], []},
    {"leads.customer_applied", "Customer applied", ~w(inapp push), ~w(extension), [], [], []},
    {"leads.weekly_report", "Weekly progress report", [], [], ~w(inapp email), [], [:passes]},
    {"leads.follow_up_due", "Follow-up due", ~w(inapp extension digest), ~w(push), [], [], []},
    {"leads.untouched", "Lead untouched for a week", ~w(inapp digest), [], [], [], []},
    {"leads.job_closed", "Job closed under open leads", ~w(inapp push), [], [], [], []},
    {"leads.job_merged", "Jobs merged", ~w(inapp), [], [], [], []},
    {"leads.archive_warned", "Archive warning", ~w(inapp digest), [], [], [], []},
    {"leads.archived", "Lead archived", ~w(inapp digest), [], [], [], []},
    {"leads.purge_soon", "Purge in 7 days", ~w(inapp digest), [], [], [], []},
    # ── Conversations and triage (§5.6) ──
    {"conversations.reply_received", "Reply received", ~w(inapp push extension), [],
     ~w(inapp push digest), [], []},
    {"conversations.triage_new", "New in Triage", ~w(inapp digest), ~w(push), [], [], []},
    {"conversations.triage_stale", "Triage waiting 48 hours", ~w(inapp digest), [], [], [], []},
    {"conversations.forwarding_confirm", "Gmail forwarding code", ~w(inapp push email), [], :same,
     [], []},
    {"conversations.forwarding_silent", "Forwarding gone quiet", ~w(inapp email digest), [],
     ~w(inapp email), [], []},
    {"conversations.contact_flagged", "Contact bounced or unsubscribed", ~w(inapp digest), [], [],
     [], []},
    # ── Meetings (§5.5) ──
    {"meetings.scheduled", "Meeting scheduled", ~w(inapp push email), ~w(extension),
     ~w(inapp push email), [], []},
    {"meetings.changed", "Meeting changed", ~w(inapp push email), ~w(extension),
     ~w(inapp push email), [], []},
    {"meetings.day_before", "Meeting tomorrow", ~w(inapp push), ~w(email), ~w(inapp push email),
     [], []},
    {"meetings.reminder", "Meeting soon", ~w(inapp push extension), [], ~w(inapp push), [],
     [:passes]},
    {"meetings.proposed", "Invitation to confirm", ~w(inapp push extension), [], [], [], []},
    {"meetings.unconfirmed", "Meeting still unconfirmed", ~w(inapp push), [], [], [], []},
    {"meetings.log_outcome", "Log a meeting's outcome", ~w(inapp push), ~w(extension), [], [],
     []},
    {"meetings.clash", "Meeting clash", ~w(inapp push), [], [], [], []},
    # ── Approvals (§5.4) ──
    {"approvals.requested", "Approval requested", ~w(inapp push email), ~w(extension),
     ~w(inapp push email), [], []},
    {"approvals.decided", "Approval decided", ~w(inapp push email), ~w(extension), ~w(inapp push),
     [], []},
    {"approvals.commented", "Approval comment", ~w(inapp push), [], ~w(inapp push email), [], []},
    {"approvals.due_soon", "Approval due soon", ~w(inapp push), [], :same, [], []},
    {"approvals.overdue", "Approval overdue", ~w(inapp push email), [], :same, [], []},
    {"approvals.expired", "Approval expired", ~w(inapp push email), [], :same, [], []},
    {"approvals.withdrawn", "Approval withdrawn", ~w(inapp), [], :same, [], []},
    {"approvals.sent", "Approved reply sent", [], [], ~w(inapp), [], []},
    # ── Profiles (§5.7) ──
    {"profiles.updated_by_team", "Your team updated your profile", [], [], ~w(inapp digest), [],
     []},
    {"profiles.updated_by_customer", "Customer changed their profile", ~w(inapp push), [], [], [],
     []},
    {"profiles.owners_changed", "Customer's owners changed", ~w(inapp push), [], [], [], []},
    # ── Behaviour (§5.7) ──
    {"behaviour.watch_fired", "Watch fired", ~w(inapp push extension), ~w(email), [], [], []},
    {"behaviour.watch_ending", "Watch ending", ~w(inapp digest), [], [], [], []},
    # ── System, the system admin's (§5.7) ──
    {"system.selectors_failing", "A site's selectors failing", ~w(inapp push email), [], [], [],
     []},
    {"system.delivery_failing", "Deliveries failing", ~w(inapp push email), [], [], [],
     [:passes]},
    {"system.inbound_failing", "Forwarded mail failing", ~w(inapp push email), [], [], [],
     [:passes]},
    {"system.jobs_discarded", "Background jobs discarded", ~w(inapp email), [], [], [],
     [:passes]},
    # ── Account and security (§5.1) ──
    {"account.invitation_accepted", "Invitation accepted", ~w(inapp push digest), [], [], [], []},
    {"account.invitation_expired", "Invitation expired", ~w(inapp digest), [], [], [], []},
    {"account.welcome", "Welcome", ~w(inapp email), [], :same, [], [:passes]},
    {"account.security", "Security", ~w(inapp email), [], :same, [], [:passes, :locked]},
    {"account.team_changed", "Teams and roles", ~w(inapp push), ~w(email), [], [], []},
    {"account.extension_connected", "Extension connected", ~w(inapp email), [], [], [],
     [:passes, :locked]},
    {"account.extension_off", "Extension disconnected", ~w(inapp extension), ~w(email), [], [],
     []},
    {"account.weekly_summary", "Weekly summary", ~w(inapp email), [], [], [], [:passes]},
    {"account.digest", "Digest", ~w(inapp email), [], :same, [], [:passes]},
    {"account.push_test", "Push test", ~w(inapp push), [], :same, [], [:passes]}
  ]

  @labels Map.new(@kinds, fn {key, label, _s, _so, _c, _co, _o} -> {key, label} end)
  @offered Map.new(@kinds, fn {key, _l, _s, so, _c, co, _o} -> {key, {so, co}} end)

  @doc "The groups, in their order."
  def groups, do: @groups

  @doc """
  The kinds as `{key, staff_channels, customer_channels}` in their order;
  `customer_channels` is `nil` when the same as the staff's.
  """
  def kinds do
    for {key, _label, staff, _so, customer, _co, _o} <- @kinds,
        do: {key, staff, customer_list(customer)}
  end

  @doc "Every kind's key, in order."
  def keys, do: for({key, _l, _s, _so, _c, _co, _o} <- @kinds, do: key)

  @doc "The kinds that pass quiet hours (AQ-08 §7.3, QP8-8; AQ-10B §11.4)."
  def passing_quiet_hours,
    do: for({key, _l, _s, _so, _c, _co, o} <- @kinds, :passes in o, do: key)

  @doc "The locked kinds (QP10b-4): can't be switched off; pass quiet hours and snooze."
  def locked, do: for({key, _l, _s, _so, _c, _co, o} <- @kinds, :locked in o, do: key)

  @doc """
  A kind's offered channels for an audience (§5's ○): a switch the person
  sees, off until they turn it on. `[]` for a kind this list does not know.

      iex> Data.Seeds.Notifications.offered("tasks.assigned", false)
      ["email", "extension"]
      iex> Data.Seeds.Notifications.offered("tasks.assigned", true)
      []
  """
  @spec offered(String.t(), boolean()) :: [String.t()]
  def offered(key, customer?) do
    case Map.get(@offered, key) do
      nil -> []
      {staff, _customer} when not customer? -> staff
      {_staff, customer} -> customer
    end
  end

  @doc """
  A kind's label, as settings and delivery health name it; the key itself
  for a kind this list does not know.

      iex> Data.Seeds.Notifications.label("approvals.requested")
      "Approval requested"
  """
  @spec label(String.t()) :: String.t()
  def label(key), do: Map.get(@labels, key, key)

  @doc "A group's label; the key itself for a group this list does not know."
  @spec group_label(String.t()) :: String.t()
  def group_label(key) do
    Enum.find_value(@groups, key, fn g -> g.key == key && g.label end)
  end

  @doc "Loads the groups, then the kinds. Answers `%{inserted, updated, kept}`."
  @spec load(keyword()) :: %{
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          kept: non_neg_integer()
        }
  def load(_opts \\ []) do
    groups = Enum.map(@groups, &Notifications.upsert_group/1)

    kinds =
      Enum.map(@kinds, fn {key, _label, staff, _so, customer, _co, options} ->
        Notifications.upsert_kind(%{
          key: key,
          notification_group_key: key |> String.split(".") |> hd(),
          default_channels: staff,
          customer_channels: customer_list(customer),
          can_ignore_quiet_hours: :passes in options,
          is_locked: :locked in options
        })
      end)

    Enum.reduce(
      groups ++ kinds,
      %{inserted: 0, updated: 0, kept: 0},
      &Map.update!(&2, &1, fn n -> n + 1 end)
    )
  end

  defp customer_list(:same), do: nil
  defp customer_list(list) when is_list(list), do: list
end
