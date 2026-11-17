defmodule ApiShared.DashboardsJSON do
  @moduledoc """
  The dashboards' shapes (AQ-11 §7.4), exactly as pinned: keys snake_case,
  an optional member `null`, rates integer basis points (or `null`) beside
  their counts with `few`. `Core.Dashboards` builds the maps; this module
  names every key, so nothing else leaks into the answer.
  """

  @doc "*My numbers*."
  def me(m) do
    %{
      period: period(m.period),
      person: person(m.person),
      target: %{
        today: m.target.today,
        done_today: m.target.done_today,
        run: Enum.map(m.target.run, &%{on: &1.on, done: &1.done, target: &1.target})
      },
      tiles: %{
        applications: m.tiles.applications,
        responses: rate(m.tiles.responses),
        interviews: m.tiles.interviews,
        follow_ups_due: m.tiles.follow_ups_due,
        triage: m.tiles.triage,
        approvals_waiting: m.tiles.approvals_waiting,
        tasks_due: m.tiles.tasks_due
      },
      by_profile:
        Enum.map(m.by_profile, fn r ->
          %{
            profile: %{
              id: r.profile.id,
              title: r.profile.title,
              customer: %{
                id: r.profile.customer.id,
                display_name: r.profile.customer.display_name
              }
            },
            count: r.count
          }
        end),
      by_platform: Enum.map(m.by_platform, &%{platform: &1.platform, count: &1.count}),
      due_today: Enum.map(m.due_today, &Map.take(&1, ~w(kind id title line at link_path)a)),
      upcoming_meetings:
        Enum.map(m.upcoming_meetings, fn x ->
          x
          |> Map.take(~w(id title starts_at ends_at time_zone)a)
          |> Map.put(:lead, x.lead && Map.take(x.lead, [:id, :title]))
        end),
      recent_applications:
        Enum.map(m.recent_applications, fn r ->
          r
          |> Map.take(~w(lead_id title company applied_at state)a)
          |> Map.put(:profile, Map.take(r.profile, [:id, :title]))
          |> Map.put(:stage, r.stage && Map.take(r.stage, [:key, :label]))
        end),
      about_to_archive:
        Enum.map(m.about_to_archive, &Map.take(&1, ~w(lead_id title company archives_on)a))
    }
  end

  @doc "*Team*."
  def team(t) do
    %{
      period: period(t.period),
      team: t.team && Map.take(t.team, [:id, :name]),
      members:
        Enum.map(t.members, fn m ->
          %{
            user: person(m.user),
            today: m.today,
            target_today: m.target_today,
            period_count: m.period_count,
            responses: rate(m.responses),
            interviews: m.interviews,
            triage: m.triage
          }
        end),
      funnel: %{
        cohort: period(t.funnel.cohort),
        steps: Enum.map(t.funnel.steps, &Map.take(&1, [:key, :count, :rate_bp]))
      },
      rates: %{
        by_profile:
          Enum.map(t.rates.by_profile, &rated(&1, :profile, Map.take(&1.profile, [:id, :title]))),
        by_platform: Enum.map(t.rates.by_platform, &rated(&1, :platform, &1.platform)),
        by_skill: Enum.map(t.rates.by_skill, &rated(&1, :skill, Map.take(&1.skill, [:id, :name])))
      },
      stuck: %{
        quiet_30: Enum.map(t.stuck.quiet_30, &lead_row/1),
        quiet_60: Enum.map(t.stuck.quiet_60, &lead_row/1)
      },
      overrides:
        Enum.map(t.overrides, fn o ->
          o |> Map.take(~w(lead_id title at reason)a) |> Map.put(:by, person(o.by))
        end),
      admin: t.admin && admin(t.admin)
    }
  end

  @doc "The customer's *Home*."
  def home(h) do
    %{
      profiles:
        Enum.map(h.profiles, fn p ->
          %{
            profile: Map.take(p.profile, [:id, :title]),
            this_week: p.this_week,
            last_week: p.last_week,
            stages: Enum.map(p.stages, &Map.take(&1, [:key, :label, :count]))
          }
        end),
      next: %{
        meetings:
          Enum.map(h.next.meetings, &Map.take(&1, ~w(id title starts_at ends_at time_zone)a)),
        approvals: Enum.map(h.next.approvals, &Map.take(&1, [:id, :title, :due_at])),
        tasks: Enum.map(h.next.tasks, &Map.take(&1, [:id, :title, :due_on]))
      },
      replies:
        h.replies &&
          Enum.map(h.replies, &Map.take(&1, ~w(lead_id title from_name at excerpt)a))
    }
  end

  defp period(p), do: Map.take(p, [:key, :from, :to, :label])

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, [:id, :name])

  defp rate(r), do: Map.take(r, [:count, :of, :rate_bp, :few])

  defp rated(row, key, value),
    do: %{
      key => value,
      count: row.count,
      responses: row.responses,
      rate_bp: row.rate_bp,
      few: row.few
    }

  defp lead_row(r) do
    r |> Map.take(~w(lead_id title company quiet_days)a) |> Map.put(:owner, person(r.owner))
  end

  defp admin(a) do
    %{
      retention: %{
        archive_next: Enum.map(a.retention.archive_next, &lead_row/1),
        purge_next: Enum.map(a.retention.purge_next, &lead_row/1)
      },
      extension: Enum.map(a.extension, &Map.take(&1, [:site, :misses_7d, :last_capture_at]))
    }
  end
end
