defmodule Core.Companies do
  @moduledoc """
  Companies (AQ-03 QP3-6): the job form's picker, the card on a job, its
  edit sheet. Any staff member adds and edits one (§4.2); the customer
  reaches none (`Core.Access`, `{:company, _}`). A name is one company per
  organisation, compared normalised ("bamboo invest" is *Bamboo Invest*);
  every write is audited in its transaction. The list, contacts and merge
  are P6's. Companies are the organisation's, not a team's (QT-2); the
  card's `open_jobs` lists only the open jobs of the teams the caller is in
  (an admin: every team) that the caller may see (AQ-03B §5.1).

  **P10** (AQ-10 §6.3, §11.4): the card gains `time_zone` and
  `time_zone_source`, and `GET`, `POST` and `PATCH` answer it with the
  `behaviour` summary (`nil` when the caller may not read it). `PATCH`
  takes `time_zone` — an IANA name sets it by hand (`manual`, which an
  Upwork capture never overwrites), `null` clears both — and a capture
  sets it from the Upwork client's local time (`put_upwork_zone/4`).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Tasks.Person
  alias Data.Companies, as: Store
  alias Data.Companies.Company
  alias Data.Repo
  alias Data.Scope

  @audited ~w(name domain website_url linkedin_url size_band industry hq_country notes_md
              time_zone time_zone_source)a

  @doc """
  `GET /companies?$where`: at most 20, by name, `[{id, name, domain}]`;
  `$where` is `Data.Filters.Companies`' (`q`).
  """
  @spec search(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def search(%Scope{} = scope, params) do
    with :ok <- Access.why_not(scope, :read, {:company, %{}}),
         {:ok, companies} <- Store.search(Scope.organisation_id(scope), where_of(params)),
         do: {:ok, Enum.map(companies, &%{id: &1.id, name: &1.name, domain: &1.domain})}
  end

  defp where_of(%{} = params), do: params["$where"] || params[:"$where"]
  defp where_of(_params), do: nil

  @doc "`GET /companies/:id`: the card, with its open jobs and its `behaviour`."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, company} <- fetch(scope, :read, id), do: {:ok, card(scope, company, now)}
  end

  @doc "`POST /companies`: a new company, audited; a name already taken is a field error."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :create, {:company, %{}}),
         {:ok, company} <- Repo.transaction(fn -> insert(scope, params, now) end),
         do: {:ok, card(scope, company, now)}
  end

  @doc """
  `PATCH /companies/:id`: any of its fields, audited with what changed;
  `time_zone` an IANA name (`time_zone_source: manual`) or `null` (both
  cleared).
  """
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, company} <- fetch(scope, :update, id),
         {:ok, updated} <- Repo.transaction(fn -> save(scope, company, params, now) end),
         do: {:ok, card(scope, updated, now)}
  end

  defp card(scope, company, now) do
    scope
    |> view(company)
    |> Map.put(:behaviour, Core.Behaviour.summary_for(scope, :company, company.id, now))
  end

  @doc """
  Inside a capture's transaction: the Upwork client's zone on the company,
  unless one was set by hand or it is already that one. Audited as an
  edit.
  """
  @spec put_upwork_zone(Scope.t(), binary() | nil, String.t() | nil, DateTime.t()) :: :ok
  def put_upwork_zone(%Scope{} = scope, company_id, zone, %DateTime{} = now)
      when is_binary(company_id) and is_binary(zone) do
    with %Company{} = company <- Store.get(Scope.organisation_id(scope), company_id),
         true <- company.time_zone_source != :manual and company.time_zone != zone,
         {:ok, updated} <- Store.put_zone(company, zone, :upwork) do
      {before, after_} = changed(company, updated)

      {:ok, _event} =
        Audit.record(scope, "updated", updated, before: before, after: after_, now: now)

      :ok
    else
      _kept -> :ok
    end
  end

  def put_upwork_zone(_scope, _company_id, _zone, _now), do: :ok

  @doc "The company behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Company.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Company{} = company <-
           Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:company, company}),
         do: {:ok, company}
  end

  @doc false
  # Inside a transaction: the company named `name` (normalised), else a new
  # one with `website_url` — the job form's `company: {name, website_url?}`
  # — and the extension's `linkedin_url` (AQ-05 §10.1).
  def find_or_insert(%Scope{} = scope, %{} = params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    case Store.get_by_name(Scope.organisation_id(scope), params["name"]) do
      %Company{} = company -> company
      nil -> insert(scope, Map.take(params, ["name", "website_url", "linkedin_url"]), now)
    end
  end

  defp insert(scope, params, now) do
    attrs =
      params
      |> fields()
      |> Map.merge(%{
        "organisation_id" => Scope.organisation_id(scope),
        "created_by_user_id" => Scope.user_id(scope)
      })

    case Store.create(attrs) do
      {:ok, company} ->
        {:ok, _event} =
          Audit.record(scope, "created", company, after: snapshot(company), now: now)

        company

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp save(scope, company, params, now) do
    with {:ok, zoned} <- zone(company, params),
         {:ok, updated} <- Store.update(zoned, fields(params)) do
      {before, after_} = changed(company, updated)

      if before != %{} do
        {:ok, _event} =
          Audit.record(scope, "updated", updated, before: before, after: after_, now: now)
      end

      updated
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # `time_zone` by hand: a name sets it as `manual`, `null` clears both.
  defp zone(company, params) do
    case Map.fetch(Map.new(params, fn {k, v} -> {to_string(k), v} end), "time_zone") do
      :error -> {:ok, company}
      {:ok, nil} -> Store.put_zone(company, nil, nil)
      {:ok, zone} when is_binary(zone) -> Store.put_zone(company, String.trim(zone), :manual)
      {:ok, _other} -> {:error, {:invalid, %{"time_zone" => ["is not a known IANA time zone"]}}}
    end
  end

  defp fields(params) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(Enum.map(Company.fields(), &to_string/1))
  end

  defp changed(old, new) do
    old_map = snapshot(old)
    new_map = snapshot(new)
    keys = for {k, v} <- new_map, old_map[k] != v, do: k
    {Map.take(old_map, keys), Map.take(new_map, keys)}
  end

  defp snapshot(company), do: Audit.snapshot(company, @audited)

  @doc """
  The company as the card shows it to `scope` (AQ-03 §7.1), with the open
  jobs of the caller's teams they may see; `nil` for none.
  """
  @spec view(Scope.t(), Company.t() | nil) :: map() | nil
  def view(_scope, nil), do: nil

  def view(%Scope{} = scope, %Company{} = company) do
    company = Repo.preload(company, created_by_user: [person: :photo])

    %{
      id: company.id,
      name: company.name,
      domain: company.domain,
      website_url: company.website_url,
      linkedin_url: company.linkedin_url,
      size_band: company.size_band,
      industry: company.industry,
      hq_country: company.hq_country,
      notes_md: company.notes_md,
      time_zone: company.time_zone,
      time_zone_source: company.time_zone && company.time_zone_source,
      open_jobs: open_jobs(scope, company),
      created_by: Person.view(company.created_by_user),
      inserted_at: company.inserted_at
    }
  end

  defp open_jobs(scope, company) do
    teams = if Scope.admin?(scope), do: :all, else: Scope.team_ids(scope)

    company.id
    |> Store.open_jobs(teams)
    |> Enum.filter(&Access.can?(scope, :read, {:job, &1}))
    |> Enum.map(&Map.take(&1, [:id, :title]))
  end
end
