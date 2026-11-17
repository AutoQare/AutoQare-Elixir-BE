defmodule Core.Jobs.Alerts do
  @moduledoc """
  Job-alert emails into the pool (AQ-12 §7, §11.4, QP12-23, QP12-24).
  `Core.Conversations.Alerts` reads an alert's jobs; this puts them in the
  pool and clears the ones nobody wanted.

  - **`take/4`:** for **every team that serves the receiving profile's
    customer**, each job whose key isn't in that team's pool already (nor
    merged into a job there, `Core.Jobs.Check`) becomes a job: `origin:
    email`, `origin_kind: alert`, `origin_profile_id` the receiving
    profile (the channel's first live one), with the title, company and
    location the email gives — a place that says *Remote* makes the job
    remote, *Hybrid* hybrid, any other is its on-site location. A job
    already there is left alone. Each job is its own transaction
    (`Core.Jobs.insert_new/5`), made by the system. Answers how many it
    made, across the teams.
  - **`sweep/2`** (`Core.Workers.AlertSweep`, daily): an alert job still
    live with no lead 14 days after `first_seen_at` is archived by the
    system, its audit row saying "An alert job nobody saved".
  """

  alias Core.Audit
  alias Core.Conversations.Match
  alias Core.Jobs
  alias Core.Jobs.Check
  alias Data.Jobs, as: Store
  alias Data.Repo
  alias Data.Scope

  @unsaved_days 14
  @swept "An alert job nobody saved"

  @doc "The days an alert job waits for a lead before the sweep archives it."
  @spec unsaved_days() :: pos_integer()
  def unsaved_days, do: @unsaved_days

  @doc """
  An alert's `jobs` (`Core.Conversations.Alerts.read/1`'s) into the pools of
  the teams serving the customer of `channel`'s receiving profile. Answers
  how many jobs it made.
  """
  @spec take(Scope.t(), map(), [map()], DateTime.t()) :: non_neg_integer()
  def take(%Scope{} = scope, channel, jobs, %DateTime{} = now) do
    case Match.profiles(channel) do
      [] ->
        0

      [profile | _rest] ->
        Enum.sum(
          for team <- teams(scope, channel.customer),
              job <- jobs,
              made?(scope, team, profile, job, now),
              do: 1
        )
    end
  end

  defp teams(scope, customer) do
    org = Scope.organisation_id(scope)

    for team_id <- Data.Customers.fill(customer).team_ids,
        %{archived_at: nil} = team <- [Data.Teams.get(org, team_id)],
        do: team
  end

  defp made?(scope, team, profile, job, now) do
    with :none <- Check.existing(team.id, job.key),
         {:ok, _job} <-
           Jobs.insert_new(scope, team, body(job), now,
             link: Map.take(job, [:key, :source, :source_job_id, :url]),
             origin: :email,
             origin_kind: :alert,
             origin_profile_id: profile.id
           ) do
      true
    else
      _held_or_refused -> false
    end
  end

  @doc """
  What the email says about a job, as P3's job body.

      iex> Core.Jobs.Alerts.body(%{title: "Go Developer", company: "Acme", location: "Remote", source: :indeed, source_job_id: "ab12"})
      %{"title" => "Go Developer", "company" => %{"name" => "Acme"}, "workplace" => "remote"}
      iex> Core.Jobs.Alerts.body(%{title: nil, company: nil, location: "Karachi, Sindh, Pakistan (Hybrid)", source: :linkedin, source_job_id: "42"})
      %{"title" => "LinkedIn job 42", "workplace" => "hybrid", "onsite_locations" => ["Karachi, Sindh, Pakistan"]}
  """
  @spec body(map()) :: map()
  def body(job) do
    %{"title" => job.title || "#{platform(job.source)} job #{job.source_job_id}"}
    |> put_company(job.company)
    |> Map.merge(place(job.location))
  end

  defp put_company(body, nil), do: body
  defp put_company(body, name), do: Map.put(body, "company", %{"name" => name})

  defp place(nil), do: %{}

  defp place(location) do
    bare =
      location |> String.replace(~r/\s*\((?:remote|hybrid|on-?site)\)\s*/i, "") |> String.trim()

    cond do
      location =~ ~r/\bremote\b/i -> %{"workplace" => "remote"}
      location =~ ~r/\bhybrid\b/i -> %{"workplace" => "hybrid", "onsite_locations" => [bare]}
      bare == "" -> %{}
      true -> %{"onsite_locations" => [bare]}
    end
  end

  defp platform(:linkedin), do: "LinkedIn"
  defp platform(:indeed), do: "Indeed"
  defp platform(other), do: other |> to_string() |> String.capitalize()

  # ── The sweep ───────────────────────────────────────────────────────────────

  @doc """
  Alert jobs nobody saved, archived (QP12-24): live, no lead, first seen
  14 days or more before `now`. Answers how many; a second run archives
  nothing.
  """
  @spec sweep(Scope.t(), DateTime.t()) :: non_neg_integer()
  def sweep(%Scope{via: :system}, %DateTime{} = now) do
    now
    |> DateTime.add(-@unsaved_days, :day)
    |> Store.unsaved_alerts_for_system()
    |> Enum.count(&swept?(&1, now))
  end

  defp swept?(job, now) do
    scope = Scope.system(Data.Organisations.get(job.organisation_id))

    {:ok, _job} =
      Repo.transaction(fn ->
        {:ok, archived} = Store.archive(job, now, nil)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: %{"archived_at" => nil},
            after: %{"archived_at" => now, "reason" => @swept},
            now: now
          )

        archived
      end)

    true
  end
end
