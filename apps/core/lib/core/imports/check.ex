defmodule Core.Imports.Check do
  @moduledoc """
  The dry run (AQ-12 §11.4): every row through the same canonical key, job
  check and duplicate guard a real save uses — **writing nothing** but the
  row's own `values`, `result` and `reasons`.

  Per row, after `Core.Imports.Values` (whose errors make it an `error`):

  - **applications**: the same key and profile earlier in the file →
    `duplicate` ("Same as row 379 after link cleanup"); a lead of the
    profile in this team (`Core.Leads.Guard.assess/5`) → `update` when the
    row fills a blank field of its job (`Core.Imports.Fill`; the reasons
    name the fields), else `duplicate` ("Already applied with Naveed ·
    Golang on 16 Oct"); a lead in another team, or a purged one's
    tombstone, → `duplicate`; another profile of the same customer →
    `new`, with the guard's warning in the reasons; everything else `new`.
    A new job needs a title (`no_title`).
  - **jobs**: the same key earlier in the file → `duplicate`; a job of the
    team's pool with that key → `update` or `duplicate` as above; else
    `new`. A Fiverr link has no key and is always new.
  - **contacts**: the same handle earlier in the file → `duplicate`; a
    contact holding one of its handles → `update` (blank title, company,
    notes) or `duplicate`; else `new`.

  A tab left out marks its rows `skipped`, as does a person's *Skip*
  (kept through a re-check).
  """

  alias Core.Contacts
  alias Core.Imports.{Fill, Values}
  alias Core.Jobs.Check, as: JobCheck
  alias Core.Leads.{Guard, Words}
  alias Data.Imports.{Import, Row}
  alias Data.Organisations
  alias Data.Profiles
  alias Data.Scope
  alias Data.Skills
  alias Data.Teams

  @doc """
  What a dry run of `import` reads once: the kind, mapping and order, the
  team's people and its customers' live profiles, the skills, *today* and
  the zone, the no-response cut-off, and each tab's choices.
  """
  @spec context(Scope.t(), Import.t(), DateTime.t()) :: map()
  def context(%Scope{} = scope, %Import{} = import, %DateTime{} = now) do
    org_id = import.organisation_id
    zone = Core.Tasks.zone(scope)

    profiles =
      org_id
      |> Profiles.live_in_organisation()
      |> Enum.filter(
        &(import.team_id in &1.customer.team_ids and &1.customer.status not in [:paused, :ended])
      )

    %{
      kind: to_string(import.kind),
      team_id: import.team_id,
      mapping: import.mapping,
      date_order: import.date_order,
      overwrite: import.overwrite,
      today: now |> DateTime.shift_zone!(zone) |> DateTime.to_date(),
      zone: zone,
      cutoff: Organisations.get_settings(org_id).no_response_days,
      members:
        Enum.map(
          Teams.list_members(import.team_id),
          &%{id: &1.user_id, name: &1.user.person.display_name, email: &1.user.email}
        ),
      profile_structs: Map.new(profiles, &{&1.id, &1}),
      profiles:
        Enum.map(
          profiles,
          &%{id: &1.id, title: &1.title, customer_name: &1.customer.display_name}
        ),
      skills: Enum.map(Skills.list(org_id), &%{id: &1.id, name: &1.name}),
      tabs:
        Map.new(import.tabs, fn tab ->
          {tab["name"],
           %{
             profile_id: tab["profile_id"],
             applier_user_id: tab["applier_user_id"],
             include: tab["include"] != false
           }}
        end)
    }
  end

  @doc """
  Every row of the file, in the tabs' order then by row number: `[{row,
  attrs}]`, `attrs` the row's `values`, `result` and `reasons`.
  """
  @spec rows(Scope.t(), map(), [Row.t()], [String.t()]) :: [{Row.t(), map()}]
  def rows(%Scope{} = scope, ctx, rows, tab_order) do
    rows
    |> Enum.sort_by(
      &{Enum.find_index(tab_order, fn name -> name == &1.tab end) || 0, &1.row_number}
    )
    |> Enum.map_reduce(%{}, fn row, seen ->
      {attrs, seen} = row(scope, ctx, row, seen)
      {{row, attrs}, seen}
    end)
    |> elem(0)
  end

  @doc """
  One row checked against what came before it (`seen`: the keys of the
  earlier rows, `%{key => {tab, row_number, link}}`): `{attrs, seen}`.
  """
  @spec row(Scope.t(), map(), Row.t(), map()) :: {map(), map()}
  def row(%Scope{} = scope, ctx, %Row{} = row, seen) do
    tab = Map.get(ctx.tabs, row.tab, %{profile_id: nil, applier_user_id: nil, include: true})

    cond do
      by_hand?(row) ->
        {%{result: :skipped, reasons: row.reasons}, seen}

      not tab.include ->
        {%{
           result: :skipped,
           reasons: [Values.reason("tab_left_out", "This tab isn't imported.")]
         }, seen}

      true ->
        {values, reasons} = Values.read(Map.put(ctx, :tab, tab), row.cells)

        if Values.errors(reasons) != [],
          do: {%{values: values, result: :error, reasons: reasons}, seen},
          else: guard(scope, ctx, row, {values, reasons}, seen)
    end
  end

  @doc """
  What came before a row, from the earlier rows' kept values (a row
  edited in the preview is checked again against them): `seen` as `row/4`
  takes it.
  """
  @spec seen_from(map(), [Row.t()]) :: map()
  def seen_from(ctx, earlier) do
    earlier
    |> Enum.filter(&(&1.result in [:new, :update, :duplicate]))
    |> Enum.reduce(%{}, fn row, seen ->
      here = {row.tab, row.row_number, row.values["link_written"]}
      Enum.reduce(keys(ctx.kind, row.values), seen, &Map.put_new(&2, &1, here))
    end)
  end

  defp keys("applications", values), do: [{values["key"], values["profile_id"]}]
  defp keys("jobs", values), do: [values["key"] || {:link, values["job_url"]}]

  defp keys("contacts", values) do
    case Contacts.handles(handles(values)) do
      {:ok, handles} -> Enum.map(handles, &{&1.kind, &1.normalized})
      _bad -> []
    end
  end

  @doc "Whether a person skipped the row (*Skip*), which a re-check keeps."
  @spec by_hand?(Row.t()) :: boolean()
  def by_hand?(%Row{result: :skipped, reasons: reasons}),
    do: Enum.any?(reasons, &(&1["code"] == "skipped"))

  def by_hand?(_row), do: false

  # ── The guard's rules, per kind ─────────────────────────────────────────────

  defp guard(scope, %{kind: "applications"} = ctx, row, {values, reasons}, seen) do
    key = {values["key"], values["profile_id"]}

    case Map.get(seen, key) do
      nil ->
        attrs = application(scope, ctx, values, reasons)
        {attrs, Map.put(seen, key, {row.tab, row.row_number, values["link_written"]})}

      earlier ->
        {same_as(values, reasons, earlier, row), seen}
    end
  end

  defp guard(_scope, %{kind: "jobs"} = ctx, row, {values, reasons}, seen) do
    key = values["key"] || {:link, values["job_url"]}

    case Map.get(seen, key) do
      nil ->
        attrs = job(ctx, values, reasons)
        {attrs, Map.put(seen, key, {row.tab, row.row_number, values["link_written"]})}

      earlier ->
        {same_as(values, reasons, earlier, row), seen}
    end
  end

  defp guard(scope, %{kind: "contacts"} = ctx, row, {values, reasons}, seen) do
    case Contacts.handles(handles(values)) do
      {:ok, handles} ->
        keys = Enum.map(handles, &{&1.kind, &1.normalized})

        case Enum.find_value(keys, &Map.get(seen, &1)) do
          nil ->
            attrs = contact(scope, ctx, values, reasons, handles)
            here = {row.tab, row.row_number, nil}
            {attrs, Enum.reduce(keys, seen, &Map.put(&2, &1, here))}

          earlier ->
            {same_as(values, reasons, earlier, row), seen}
        end

      {:error, {:invalid, details}} ->
        words = details |> Map.values() |> List.flatten() |> Enum.join(", ")
        bad = Values.reason("bad_handle", "A handle #{words}.")
        {%{values: values, result: :error, reasons: reasons ++ [bad]}, seen}
    end
  end

  defp application(scope, ctx, values, reasons) do
    profile = Map.fetch!(ctx.profile_structs, values["profile_id"])
    found = job_of(ctx.team_id, values["key"])
    assessed = Guard.assess(scope, values["key"], ctx.team_id, profile)
    here = assessed.lead && assessed.lead.job.team_id == ctx.team_id && assessed.lead

    cond do
      here ->
        existing = Values.reason("existing_lead", already(ctx, profile, here, "this"))
        job = Data.Jobs.reload(here.job)
        fills(values, reasons ++ [existing], Fill.job(job, values, ctx.overwrite))

      assessed.lead ->
        duplicate(values, reasons, already(ctx, profile, assessed.lead, "another"))

      assessed.fingerprint ->
        {:duplicate_application, %{message: words}} =
          Guard.tombstone(scope, assessed.fingerprint, ctx.team_id, profile)

        duplicate(values, reasons, words)

      true ->
        warned = reasons ++ same_customer(assessed.same_customer, profile)
        fresh(values, warned, found)
    end
  end

  defp job(ctx, values, reasons) do
    case values["key"] && job_of(ctx.team_id, values["key"]) do
      %{} = job ->
        existing = Values.reason("existing_job", "Already in the pool: #{job.title}.")
        fills(values, reasons ++ [existing], Fill.job(job, values, ctx.overwrite))

      _none ->
        fresh(values, reasons, nil)
    end
  end

  defp contact(scope, ctx, values, reasons, handles) do
    case Contacts.assess(scope, values["name"], nil, handles) do
      %{answer: :exact, contact: held} ->
        existing = Values.reason("existing_contact", "Already a contact: #{held.name}.")
        fills(values, reasons ++ [existing], Fill.contact(held, values, ctx.overwrite))

      _new_or_possible ->
        %{values: values, result: :new, reasons: reasons}
    end
  end

  defp job_of(_team_id, nil), do: nil

  defp job_of(team_id, key) do
    case JobCheck.existing(team_id, key) do
      {:job, job} -> job
      {:merged, job, _merge} -> job
      :none -> nil
    end
  end

  # A new job needs its title; a job the pool holds has one.
  defp fresh(values, reasons, found) do
    if is_nil(found) and is_nil(values["title"]),
      do: %{
        values: values,
        result: :error,
        reasons: reasons ++ [Values.reason("no_title", "No job title.")]
      },
      else: %{values: values, result: :new, reasons: reasons}
  end

  defp fills(values, reasons, []),
    do: %{values: values, result: :duplicate, reasons: reasons}

  defp fills(values, reasons, plan) do
    filled = Map.new(plan, fn {key, _value} -> {key, true} end)

    %{
      values: Map.put(values, "fills", Map.keys(filled)),
      result: :update,
      reasons: reasons ++ [Values.reason("fills", Fill.words(plan))]
    }
  end

  defp duplicate(values, reasons, words),
    do: %{
      values: values,
      result: :duplicate,
      reasons: reasons ++ [Values.reason("duplicate", words)]
    }

  # The link as the sheet wrote it is compared, so a link `Utils.JobKey`
  # cleaned (tracking parameters, `www.`) says so.
  defp same_as(values, reasons, {tab, n, link}, row) do
    where = if tab == row.tab, do: "row #{n}", else: "row #{n} of “#{tab}”"
    cleaned = if link && link != values["link_written"], do: " after link cleanup", else: ""
    duplicate(values, reasons, "Same as #{where}#{cleaned}.")
  end

  defp already(ctx, profile, lead, team) do
    who = "#{profile.customer.display_name} · #{profile.title}"

    {verb, at} =
      if lead.applied_at, do: {"applied", lead.applied_at}, else: {"saved", lead.inserted_at}

    where = if team == "another", do: " in another team", else: ""
    "Already #{verb} with #{who}#{where} on #{Words.day(at, ctx.zone)}."
  end

  defp same_customer([], _profile), do: []

  defp same_customer([other | _rest], profile) do
    words =
      "#{profile.customer.display_name}'s #{Words.quoted(other.profile.title)} already has " <>
        "a lead on this job."

    [Values.reason("same_customer", words)]
  end

  defp handles(values) do
    for {kind, field} <- [email: "email", linkedin: "linkedin", phone: "phone"],
        value = values[field],
        do: %{"kind" => to_string(kind), "value" => value}
  end
end
