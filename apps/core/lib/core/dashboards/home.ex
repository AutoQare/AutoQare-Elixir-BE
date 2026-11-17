defmodule Core.Dashboards.Home do
  @moduledoc """
  The customer's *Home* (AQ-11 §3.4, §7.4, QP11-15): `GET /client/v1/home`,
  their own profiles only, the teams' settings applied. **No targets**.

  | Part | Is |
  |---|---|
  | `profiles` | each live profile: applications `this_week` and `last_week` (calendar weeks from Monday in the organisation's zone, as the tiles count them) and `stages`, its live leads In progress or On hold by their stage, in the pipeline's order |
  | `next` | scheduled meetings of their leads in the next 30 days (10 at most); approvals waiting on them; tasks given to them (`assigned`), open |
  | `replies` | the employers' last 10 replies on their leads, only from teams that let them see conversations — `null` when none does; `from_name` `null` where the lead's team hides names |
  """

  alias Core.Access
  alias Core.Approvals
  alias Core.Dashboards
  alias Core.Dashboards.Windows
  alias Core.Leads
  alias Core.Tasks.Visibility
  alias Data.Dashboards.Rows
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @next_days 30
  @next 10
  @replies 10
  @excerpt 160

  @doc "The customer's *Home* at `now`; staff find nothing."
  @spec build(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def build(%Scope{} = scope, %DateTime{} = now) do
    if Scope.customer?(scope), do: {:ok, home(scope, now)}, else: {:error, :not_found}
  end

  defp home(scope, now) do
    customer_id = Scope.customer_id(scope)
    customer = Data.Customers.get(Scope.organisation_id(scope), customer_id)
    zone = Dashboards.zone(scope)
    today = Windows.today(now, zone)
    settings = Teams.settings_for(customer.team_ids)

    %{
      profiles: profiles(scope, customer_id, now, zone),
      next: %{
        meetings: meetings(scope, {now, Windows.start_of(Date.add(today, @next_days + 1), zone)}),
        approvals:
          Enum.map(Approvals.waiting(scope), &%{id: &1.id, title: &1.title, due_at: &1.due_at}),
        tasks: tasks(scope, zone)
      },
      replies: replies(scope, settings)
    }
  end

  defp profiles(scope, customer_id, now, zone) do
    who = {:customer, customer_id}
    week = Windows.period(:week, now, zone)

    windows = %{
      this_week: {week.from, week.to},
      last_week: Windows.window(Date.add(week.first, -7), Date.add(week.last, -7), zone)
    }

    counts = scope |> Dashboards.applications(who, windows, :profile) |> Map.new(&{&1.group, &1})

    stages =
      scope
      |> Dashboards.lead_subject(who)
      |> Rows.stage_counts()
      |> Enum.group_by(& &1.profile_id)

    for p <- Data.Profiles.list(customer_id) do
      c = Map.get(counts, p.id, %{this_week: %{count: 0}, last_week: %{count: 0}})

      %{
        profile: %{id: p.id, title: p.title},
        this_week: c.this_week.count,
        last_week: c.last_week.count,
        stages: stages |> Map.get(p.id, []) |> in_order()
      }
    end
  end

  # One entry per stage key, in the engine's order (a custom stage at its anchor).
  defp in_order(rows) do
    order =
      Vocabulary.stage_kinds() |> Enum.map(&String.to_atom/1) |> Enum.with_index() |> Map.new()

    rows
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, [first | _rest] = same} ->
      kind = if first.kind == :custom, do: first.anchor_kind, else: first.kind

      {{Map.get(order, kind, 99), first.kind == :custom, first.position},
       %{key: key, label: first.name, count: same |> Enum.map(& &1.count) |> Enum.sum()}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp meetings(scope, window) do
    scope
    |> Dashboards.lead_subject({:customer, Scope.customer_id(scope)})
    |> Rows.meetings(window)
    |> Enum.filter(&Access.can?(scope, :read, {:lead, Leads.subject(&1.lead)}))
    |> Enum.take(@next)
    |> Enum.map(
      &%{
        id: &1.id,
        title: &1.title,
        starts_at: &1.starts_at,
        ends_at: &1.ends_at,
        time_zone: &1.time_zone
      }
    )
  end

  defp tasks(scope, zone) do
    for t <- Data.Tasks.list(Visibility.filter(scope)),
        t.customer_access == :assigned,
        t.state in [:todo, :in_progress, :on_hold] do
      %{id: t.id, title: t.title, due_on: t.due_on || (t.due_at && Windows.today(t.due_at, zone))}
    end
  end

  defp replies(scope, settings) do
    case for {team_id, s} <- settings, s.customer_sees_conversations, do: team_id do
      [] ->
        nil

      teams ->
        for r <-
              scope
              |> Dashboards.lead_subject({:customer, Scope.customer_id(scope)})
              |> Rows.replies(teams, @replies) do
          %{
            lead_id: r.lead_id,
            title: title(r),
            from_name:
              if(settings[r.team_id].customer_sees_staff_names,
                do: r.contact_name || Core.Conversations.names_only(r.from_text)
              ),
            at: r.sent_at,
            excerpt: excerpt(r.body_text)
          }
        end
    end
  end

  defp title(%{job_title: t, company_name: nil}), do: t
  defp title(%{job_title: t, company_name: c}), do: t <> " · " <> c

  defp excerpt(nil), do: nil

  defp excerpt(text) do
    squished = text |> String.split() |> Enum.join(" ")

    if String.length(squished) > @excerpt,
      do: String.slice(squished, 0, @excerpt - 1) <> "…",
      else: squished
  end
end
