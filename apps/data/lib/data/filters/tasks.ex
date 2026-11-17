defmodule Data.Filters.Tasks do
  @moduledoc """
  The tasks board's `$where` (`GET /team/v1/board`, AQ-11B §3 #4), and the
  relation picker's (`GET /tasks/search`). The tasks the caller sees in the
  team (`Data.Tasks.visible/2`, access) are the base query's; this narrows
  them, in SQL — P2's filters that ran in memory included.

  | Field | Operators | Is |
  |---|---|---|
  | `mine` | `$EQUAL` `true` | assigned to me, my open steps on other tasks (shown as step cards), my drafts and my own tasks nobody is on (QP2-16) |
  | `watching` | `$EQUAL` `true` | the tasks I watch |
  | `customer_id` | `$EQUAL` | the customer's tasks (`Core.Tasks.Board` checks the caller may read the customer: 404 otherwise) |
  | `archived` | `$EQUAL` `true` · `false` | only the archived, or only the live (the default) |
  | `q` | `$ILIKE` | the title holds the words, any case |
  | `priority` | `$EQUAL` `$IN` | `urgent` · `high` · `normal` (no priority) · `low` |
  | `due` | `$EQUAL` `$IN` | `today` · `overdue` · `week` · `none`, in the organisation's zone (below) |
  | `people` | `$EQUAL` `$IN` | user ids: one of them is on the task (primary or secondary) |
  | `profile_id` | `$EQUAL` `$IN` | the task's profile |
  | `stage_id` | `$EQUAL` `$IN` | the task's stage (a person's own stages) |
  | `no_owner` | `$EQUAL` `true` | nobody is on it |

  **`due`, with *today* the organisation's calendar day at `now`** (both
  from the context; `Utils.Days`, the dashboards' copy): *today* — due on
  today, or at an instant within it; *overdue* — still open (To do, In
  progress, On hold) and due before *now* (an instant) or before today (a
  day); *week* — due on a day from today to six days on; *none* — no due at
  all. `due {$IN: ["today", "overdue"]}` with `mine` and the open columns
  is the dashboard's *Tasks due* tile (AQ-11 §4: "tasks of yours due today
  or overdue, not done", `Core.Dashboards.Me`).

  `false` for `mine`, `watching` and `no_owner` filters nothing.
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [
      customer_id: ["$EQUAL"],
      profile_id: ["$EQUAL", "$IN"],
      stage_id: ["$EQUAL", "$IN"]
    ],
    overrideable: ["mine", "watching", "archived", "q", "priority", "due", "people", "no_owner"],
    ignoreable: [
      q: ["", "%%", nil],
      priority: ["", nil, []],
      due: ["", nil, []],
      people: ["", nil, []],
      customer_id: ["", nil],
      profile_id: ["", nil, []],
      stage_id: ["", nil, []]
    ]

  use Data.Filters,
    operators: [
      mine: ["$EQUAL"],
      watching: ["$EQUAL"],
      archived: ["$EQUAL"],
      q: ["$ILIKE"],
      priority: ["$EQUAL", "$IN"],
      due: ["$EQUAL", "$IN"],
      people: ["$EQUAL", "$IN"],
      no_owner: ["$EQUAL"]
    ]

  import Ecto.Query

  alias Data.Filters
  alias Data.Tasks.{Participant, Step}

  @open [:todo, :in_progress, :on_hold]
  @dues ~w(today overdue week none)

  @impl Data.Filters
  def prepare(field, "$EQUAL", value, context) when field in ["mine", "watching"] do
    case {Filters.boolean(value), context[:user_id]} do
      {{:ok, true}, me} when is_binary(me) -> {:ok, me}
      {{:ok, _either}, _me} -> {:ok, nil}
      {:error, _me} -> :error
    end
  end

  def prepare(field, "$EQUAL", value, _context) when field in ["archived", "no_owner"],
    do: Filters.boolean(value)

  def prepare("q", "$ILIKE", value, _context), do: Filters.words(value)

  def prepare("priority", _op, value, _context),
    do: Filters.keys(value, Data.Vocabulary.task_priorities() ++ ["normal"])

  def prepare("people", _op, value, _context), do: Filters.ids(value)

  def prepare("due", _op, value, %{now: %DateTime{} = now, zone: zone}) do
    with {:ok, kinds} <- Filters.keys(value, @dues) do
      {:ok, %{kinds: kinds, now: now, today: Filters.today(now, zone), zone: zone}}
    end
  end

  def prepare(_field, _op, _value, _context), do: :error

  @impl FatEcto.Query.Dynamics.Buildable
  def override_buildable("mine", "$EQUAL", me) when is_binary(me), do: mine(me)

  def override_buildable("watching", "$EQUAL", me) when is_binary(me) do
    watched = from(p in Participant, where: p.user_id == ^me and p.is_watcher, select: p.task_id)
    dynamic([t], t.id in subquery(watched))
  end

  def override_buildable("archived", "$EQUAL", true), do: dynamic([t], not is_nil(t.archived_at))
  def override_buildable("archived", "$EQUAL", false), do: dynamic([t], is_nil(t.archived_at))

  def override_buildable("q", "$ILIKE", text) when is_binary(text) do
    like = "%" <> Data.Companies.escape_like(text) <> "%"
    dynamic([t], ilike(t.title, ^like))
  end

  def override_buildable("priority", _op, keys) when is_list(keys) do
    named = Enum.reject(keys, &(&1 == :normal))

    if :normal in keys,
      do: dynamic([t], t.priority in ^named or is_nil(t.priority)),
      else: dynamic([t], t.priority in ^named)
  end

  def override_buildable("people", _op, ids) when is_list(ids) do
    on_it =
      from(p in Participant, where: p.user_id in ^ids and not is_nil(p.level), select: p.task_id)

    dynamic([t], t.id in subquery(on_it))
  end

  def override_buildable("no_owner", "$EQUAL", true),
    do: dynamic([t], t.id not in subquery(owned()))

  def override_buildable("due", _op, %{kinds: [first | rest]} = due) do
    Enum.reduce(rest, due(first, due), fn kind, acc -> dynamic(^acc or ^due(kind, due)) end)
  end

  def override_buildable(_field, _operator, _value), do: nil

  @doc """
  *Mine* (QP2-16) as a condition: assigned to me, an open step of mine, or
  mine as its author — a draft, or a task nobody is on. Also what
  `Data.Tasks.list/2`'s `{:mine, me}` narrows by.
  """
  @spec mine(binary()) :: Ecto.Query.dynamic_expr()
  def mine(me) do
    assigned =
      from(p in Participant, where: p.user_id == ^me and not is_nil(p.level), select: p.task_id)

    steps =
      from(s in Step, where: s.assignee_user_id == ^me and is_nil(s.done_at), select: s.task_id)

    dynamic(
      [t],
      t.id in subquery(assigned) or t.id in subquery(steps) or
        (t.author_user_id == ^me and (t.state == :draft or t.id not in subquery(owned())))
    )
  end

  defp owned, do: from(p in Participant, where: not is_nil(p.level), select: p.task_id)

  defp due(:none, _due), do: dynamic([t], is_nil(t.due_at) and is_nil(t.due_on))

  defp due(:today, %{today: today, zone: zone}), do: on_days(today, today, zone)

  defp due(:week, %{today: today, zone: zone}), do: on_days(today, Date.add(today, 6), zone)

  defp due(:overdue, %{now: now, today: today}) do
    dynamic([t], t.state in ^@open and (t.due_at < ^now or t.due_on < ^today))
  end

  defp on_days(first, last, zone) do
    {from, to} = Filters.day_range(first, last, zone)

    dynamic(
      [t],
      (t.due_on >= ^first and t.due_on <= ^last) or (t.due_at >= ^from and t.due_at < ^to)
    )
  end
end
