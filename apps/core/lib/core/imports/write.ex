defmodule Core.Imports.Write do
  @moduledoc """
  One row imported (AQ-12 §11.4), **in its own transaction**, so a bad row
  never stops the rest. Only `new` and `update` rows come here.

  - **applications · new**: the job by its key in the team's pool (its
    blank fields filled), or made with `origin: import` (company matched
    by name, skills, salary as written, remote and its scope, the unknown
    stack and the notes in its description); then `Core.Leads.make/4` as
    *apply* at the row's date, 12:00 in the organisation's zone, owned by
    and credited to whoever applied (`import:`: the ledger's `actor_kind:
    import`, "Imported from *file*, row *n* · by *importer*"), telling
    nobody; then its place by `Core.Imports.Statuses` (QP12-6, §3.3),
    dated in the past; then the recruiter, matched or made by handle and
    linked (`Core.Imports.People`).
  - **applications · update**: the profile's lead's job filled, a
    recruiter linked when the lead has none.
  - **jobs**: made (`origin: import`; a Fiverr link keyed by the job's own
    id) or filled. **contacts**: made (`source: import`) or filled
    (`Core.Imports.People`).

  Every fill keeps the old value (`replaced`) and the new (`created.filled`)
  so undo restores only what still holds the import's value; everything
  made is named in `created`.
  """

  alias Core.Audit
  alias Core.Companies
  alias Core.Imports.{Fill, People, Statuses}
  alias Core.Jobs
  alias Core.Jobs.Check, as: JobCheck
  alias Core.Jobs.Link
  alias Core.Leads
  alias Core.Leads.{Guard, Ledger, Words}
  alias Core.Tasks.Write, as: Tx
  alias Data.Imports.Row
  alias Data.JobParts
  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: LeadStore
  alias Data.Scope

  @sources %{
    "linkedin" => :linkedin,
    "upwork" => :upwork,
    "indeed" => :indeed,
    "wellfound" => :wellfound,
    "angellist" => :wellfound,
    "yc" => :yc_waas,
    "ycombinator" => :yc_waas,
    "work at a startup" => :yc_waas,
    "greenhouse" => :greenhouse,
    "lever" => :lever,
    "ashby" => :ashby,
    "workable" => :workable
  }

  @doc """
  Imports `row` for `ctx` (`Core.Imports.Steps`'s: the team, kind, zone,
  cut-off, today, file name, importer's name, `overwrite`): `{:ok, attrs}`
  — `job_id`, `lead_id`, `created`, `replaced` — or `{:error, reason}`,
  everything rolled back.
  """
  @spec row(Scope.t(), map(), Row.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def row(%Scope{} = scope, ctx, %Row{} = row, %DateTime{} = now) do
    Tx.commit(fn -> write(scope, ctx, row, now) end)
  end

  defp write(scope, %{kind: "applications"} = ctx, %Row{result: :new} = row, now) do
    values = row.values

    with {:ok, job, made} <- job_for(scope, ctx, values, now),
         {:ok, lead} <-
           Leads.make(scope, lead_params(ctx, job, values, now), now,
             import: imported(ctx, row, values)
           ),
         {:ok, _lead} <- place(scope, ctx, lead, values, now),
         {:ok, contacts} <- People.recruiter(scope, ctx, lead, values, now) do
      {:ok, attrs(job, {lead, :made}, Map.merge(made, contacts))}
    end
  end

  defp write(scope, %{kind: "applications"} = ctx, %Row{result: :update} = row, now) do
    values = row.values
    profile = Map.fetch!(ctx.profile_structs, values["profile_id"])

    case Guard.assess(scope, values["key"], ctx.team_id, profile).lead do
      %{job: %{team_id: team_id}} = lead when team_id == ctx.team_id ->
        job = JobStore.reload(lead.job)

        with {:ok, made} <- fill_job(scope, ctx, job, values, now),
             {:ok, contacts} <-
               People.recruiter(scope, ctx, lead, values, now, only_if_none: true) do
          {:ok, attrs(job, {lead, :found}, Map.merge(made, contacts))}
        end

      _gone ->
        {:error, {:invalid, %{"row" => ["no longer matches a lead of this team"]}}}
    end
  end

  defp write(scope, %{kind: "jobs"} = ctx, %Row{} = row, now) do
    with {:ok, job, made} <- job_for(scope, ctx, row.values, now),
         do: {:ok, attrs(job, {nil, :none}, made)}
  end

  defp write(scope, %{kind: "contacts"} = ctx, %Row{} = row, now),
    do: People.contact(scope, ctx, row.values, now)

  # `created.lead` only for a lead this row made: undo deletes what it names.
  defp attrs(job, {lead, how}, made) do
    {replaced, created} = Map.pop(made, "replaced", %{})

    %{
      job_id: job && job.id,
      lead_id: lead && lead.id,
      created: Map.put(created, "lead", if(how == :made, do: lead.id)),
      replaced: replaced
    }
  end

  # ── The job ─────────────────────────────────────────────────────────────────

  defp job_for(scope, ctx, values, now) do
    case values["key"] && existing(ctx.team_id, values["key"]) do
      %{} = job ->
        with {:ok, made} <- fill_job(scope, ctx, JobStore.reload(job), values, now),
             do: {:ok, job, made}

      _none ->
        new_job(scope, ctx, values, now)
    end
  end

  defp existing(team_id, key) do
    case JobCheck.existing(team_id, key) do
      {:job, job} -> job
      {:merged, job, _merge} -> job
      :none -> nil
    end
  end

  defp new_job(scope, ctx, values, now) do
    org_id = Scope.organisation_id(scope)

    company_existed? =
      is_nil(values["company"]) or Data.Companies.get_by_name(org_id, values["company"])

    with {:ok, opts} <- job_opts(values),
         {:ok, job} <- Jobs.insert_new(scope, ctx.team, job_body(values), now, opts) do
      company = if company_existed?, do: nil, else: job.company_id
      {:ok, job, %{"job" => job.id, "company" => company, "filled" => %{}, "replaced" => %{}}}
    end
  end

  defp job_opts(%{"fiverr" => true, "job_url" => url}) do
    id = Uniq.UUID.uuid7()

    with {:ok, link} <- Link.fiverr(Link.fiverr_job_key(id), url),
         do: {:ok, [origin: :import, id: id, link: link]}
  end

  defp job_opts(values) do
    with {:ok, link} <- Link.parse(values["job_url"]) do
      source =
        if link.source == :company_site,
          do: Map.get(@sources, platform(values["platform"]), :company_site),
          else: link.source

      {:ok, [origin: :import, link: %{link | source: source}]}
    end
  end

  defp platform(nil), do: nil

  defp platform(text),
    do: text |> String.downcase() |> String.replace(~r/[^a-z ]+/, "") |> String.trim()

  defp job_body(values) do
    remote = Fill.remote(values)

    %{
      "title" => values["title"],
      "company" => values["company"] && %{"name" => values["company"]},
      "skills" =>
        Enum.map(values["skill_ids"] || [], &%{"skill_id" => &1, "is_required" => true}),
      "comp_text" => values["salary"],
      "comp_source" => values["salary"] && "parsed_text",
      "workplace" => remote[:workplace],
      "remote_scope" => remote[:remote_scope],
      "allowed_countries" => remote[:allowed_countries] || [],
      "description_md" => description(values)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp description(values) do
    [
      stack: Enum.join(values["unknown_stack"] || [], ", "),
      company_type: values["company_type"],
      notes: values["notes"]
    ]
    |> Enum.reject(fn {_label, text} -> text in [nil, ""] end)
    |> Enum.map_join("\n\n", fn
      {:stack, text} -> "Stack: " <> text
      {:company_type, text} -> "Company type: " <> text
      {:notes, text} -> text
    end)
    |> Utils.presence()
  end

  # The job's blank fields (all, with `overwrite`), old values kept.
  defp fill_job(scope, ctx, job, values, now) do
    plan = Fill.job(job, values, ctx.overwrite)
    {columns, skills} = Enum.split_with(plan, fn {key, _v} -> key != "jobs.skills" end)

    with {:ok, columns, made} <- columns(scope, job, columns, now),
         {:ok, _job} <- if(columns == %{}, do: {:ok, job}, else: JobStore.update(job, columns)),
         :ok <- skills(job, skills) do
      replaced = Map.new(plan, fn {key, _v} -> {key, old(job, key)} end)
      filled = Map.new(plan, fn {key, v} -> {key, Map.get(made, key, v)} end)

      if plan != [] do
        {:ok, _audit} =
          Audit.record(scope, "import_filled", job, before: replaced, after: filled, now: now)
      end

      {:ok,
       %{"job" => nil, "company" => made["company"], "filled" => filled, "replaced" => replaced}}
    end
  end

  defp columns(scope, job, plan, now) do
    Enum.reduce(plan, {:ok, %{}, %{}}, fn
      {"jobs.company_id", name}, {:ok, acc, made} ->
        existed? = Data.Companies.get_by_name(job.organisation_id, name)
        company = Companies.find_or_insert(scope, %{"name" => name}, now)
        made = Map.put(made, "jobs.company_id", company.id)
        made = if existed?, do: made, else: Map.put(made, "company", company.id)
        {:ok, Map.put(acc, :company_id, company.id), made}

      {"jobs." <> column, value}, {:ok, acc, made} ->
        {:ok, Map.put(acc, String.to_existing_atom(column), value), made}
    end)
  end

  defp skills(_job, []), do: :ok

  defp skills(job, [{"jobs.skills", ids}]),
    do: JobParts.put_skills(job, Enum.map(ids, &%{skill_id: &1, is_required: true}))

  @doc false
  # A field's value now, as `replaced` keeps it (JSON-safe).
  def old(job, "jobs.skills"), do: Enum.map(job.job_skills, & &1.skill_id)
  def old(record, "jobs." <> column), do: plain(Map.get(record, String.to_existing_atom(column)))

  def old(record, "contacts." <> column),
    do: plain(Map.get(record, String.to_existing_atom(column)))

  defp plain(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp plain(value), do: value

  # ── The lead ────────────────────────────────────────────────────────────────

  defp lead_params(ctx, job, values, now) do
    %{
      "job_id" => job.id,
      "profile_id" => values["profile_id"],
      "as" => "apply",
      "owner_user_id" => values["applier_user_id"],
      "applied_at" => DateTime.to_iso8601(applied_at(ctx, values, now)),
      "document_id" => nil
    }
  end

  @doc false
  # The row's date at 12:00 in the organisation's zone, never after now.
  def applied_at(ctx, values, now) do
    noon =
      values["date"]
      |> Date.from_iso8601!()
      |> DateTime.new!(~T[12:00:00], ctx.zone)
      |> DateTime.shift_zone!("Etc/UTC")

    Enum.min([noon, now], DateTime)
  end

  defp imported(ctx, row, values) do
    %{
      applier_user_id: values["applier_user_id"],
      note: "Imported from #{ctx.file_name}, row #{row.row_number} · by #{ctx.importer_name}"
    }
  end

  # Where it stands (QP12-6, §3.3), dated in the past and credited to the
  # same person as the application.
  defp place(scope, ctx, lead, values, now) do
    applied_on = Date.from_iso8601!(values["date"])
    place = Statuses.place(values["status"], applied_on, ctx.today, ctx.cutoff)
    by = %{actor_kind: :import, actor_user_id: values["applier_user_id"]}

    case place do
      %{state: :in_progress, stage_kind: nil} ->
        {:ok, lead}

      %{state: :in_progress, stage_kind: kind} ->
        restage(scope, lead, kind, by, now)

      %{state: :done, outcome: outcome, at_days: days} ->
        at = Enum.min([DateTime.add(lead.applied_at, days, :day), now], DateTime)

        with {:ok, moved} <-
               LeadStore.update(lead, %{state: :done, outcome: outcome, finished_at: at}) do
          labels = %{
            from_label: Words.place(:in_progress, lead.stage && lead.stage.name, nil),
            to_label: Words.outcome(outcome),
            outcome: outcome,
            occurred_at: at
          }

          _event = Ledger.record(scope, moved, :outcome_set, Map.merge(labels, by), now)
          {:ok, moved}
        end
    end
  end

  defp restage(scope, lead, kind, by, now) do
    case Enum.find(lead.pipeline_version.stages, &(Ledger.engine_kind(&1) == kind)) do
      nil ->
        {:ok, lead}

      stage ->
        with {:ok, moved} <- LeadStore.update(lead, %{stage_id: stage.id}) do
          labels = %{
            from_label: lead.stage.name,
            to_label: stage.name,
            occurred_at: lead.applied_at
          }

          _event = Ledger.record(scope, moved, :stage_moved, Map.merge(labels, by), now)
          {:ok, moved}
        end
    end
  end
end
