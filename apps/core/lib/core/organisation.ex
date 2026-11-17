defmodule Core.Organisation do
  @moduledoc """
  The organisation (AQ-01 P1.1; AQ-04A §4.0): bootstrap, its settings
  (*Settings › System*, the system admin's alone), the handing on of the
  one system admin (`mix aq.admin`), the staff list and the audit log. Teams are `Core.Organisation.Teams`,
  invitations `Core.Organisation.Invitations`.

  Every write records an audit row inside its transaction (`Core.Audit`).
  Every function takes a `%Data.Scope{}` first and asks `Core.Access` before
  acting; a row the caller may not know exists is `:not_found`.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Audit.Labels
  alias Core.Leads.Pipelines
  alias Core.Notifications.Account, as: AccountNotices
  alias Core.Organisation.Invitations
  alias Data.Accounts
  alias Data.Organisations
  alias Data.Organisations.OrganisationSettings
  alias Data.Repo
  alias Data.Scope
  alias Data.Seeds.Skills, as: SkillsSeed
  alias Data.Teams

  @org_fields ~w(name slug country_code timezone currency_code)a

  # ── Bootstrap ───────────────────────────────────────────────────────────────

  @doc """
  `mix aq.bootstrap` (§3): the organisation with its default settings and an
  **admin invitation** for the email. Idempotent: run twice, it reports the
  organisation exists and re-issues the invitation if none is open. Once the
  admin invitation is accepted it refuses (`:admin_exists`): the one system
  admin is handed on with `mix aq.admin --to`. It ensures both default
  pipelines (AQ-04A §9.1).

  Answers `{:ok, %{organisation, invitation, organisation_created?, invitation: :issued | :reissued | :open}}`.
  """
  @spec bootstrap(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def bootstrap(%{org_name: org_name, admin_email: email, admin_name: name}, %DateTime{} = now) do
    Repo.transaction(fn ->
      {organisation, created?} = find_or_create_organisation(org_name, now)
      scope = Scope.system(organisation)

      # QP4a-21: one system admin. Once somebody holds it, it is handed on
      # with `mix aq.admin`, never invited again.
      if Organisations.the_admin(organisation.id), do: Repo.rollback(:admin_exists)

      :ok = Pipelines.ensure(scope, now)

      case Invitations.issue(scope, %{kind: :admin, email: email, invited_name: name}, now) do
        {:ok, invitation, status} ->
          %{
            organisation: organisation,
            invitation: invitation,
            organisation_created?: created?,
            status: status
          }

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp find_or_create_organisation(name, now) do
    case Organisations.the_one() do
      %{} = organisation ->
        {organisation, false}

      nil ->
        {:ok, organisation} = Organisations.create(%{name: name})
        {:ok, _settings} = Organisations.put_settings(organisation.id, %{})
        # The production seed for the one thing the seed cannot make (QP1-4).
        _counts = SkillsSeed.load_for(organisation.id)
        scope = Scope.system(organisation)

        {:ok, _event} =
          Audit.record(scope, "created", organisation,
            after: Audit.snapshot(organisation, @org_fields),
            now: now
          )

        {organisation, true}
    end
  end

  # ── The organisation and its settings ───────────────────────────────────────

  @doc "`GET /org`: the organisation and its timings, for the system admin."
  @spec get(Scope.t()) ::
          {:ok, %{organisation: struct(), settings: OrganisationSettings.t()}} | {:error, term()}
  def get(%Scope{organisation: organisation} = scope) do
    with :ok <- Access.why_not(scope, :read_settings, {:organisation, organisation}) do
      {:ok, %{organisation: organisation, settings: Organisations.get_settings(organisation.id)}}
    end
  end

  @doc """
  `PUT /org/settings` (and `PATCH /organisation`, AQ-10B §11.4): the
  timings, the emails' footer (`help_email`, `postal_address`) and (AQ-11
  §7.4) the `working_days` that carry a daily target, by the system admin.
  Name, timezone and currency ride along.
  """
  @spec update_settings(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_settings(%Scope{organisation: organisation} = scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    setting_params =
      Map.take(
        params,
        Enum.map(settable(), &to_string/1)
      )

    org_params = Map.take(params, ~w(name timezone currency_code country_code))

    with :ok <- Access.why_not(scope, :update_settings, {:organisation, organisation}) do
      Repo.transaction(fn -> write_settings(scope, setting_params, org_params) end)
    end
  end

  defp write_settings(%Scope{organisation: organisation} = scope, setting_params, org_params) do
    fields = settable()
    before = Audit.snapshot(Organisations.get_settings(organisation.id), fields)
    org_before = Audit.snapshot(organisation, @org_fields)

    with {:ok, settings} <- Organisations.put_settings(organisation.id, setting_params),
         {:ok, updated} <- Organisations.update(organisation, org_params) do
      {:ok, _event} =
        Audit.record(scope, "updated", settings,
          before: before,
          after: Audit.snapshot(settings, fields)
        )

      record_organisation_change(scope, org_params, org_before, updated)
      %{organisation: updated, settings: settings}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp settable,
    do:
      OrganisationSettings.fields() ++
        OrganisationSettings.texts() ++ OrganisationSettings.lists()

  defp record_organisation_change(_scope, org_params, _before, _updated) when org_params == %{},
    do: :ok

  defp record_organisation_change(scope, _org_params, before, updated) do
    {:ok, _event} =
      Audit.record(scope, "updated", updated,
        before: before,
        after: Audit.snapshot(updated, @org_fields)
      )

    :ok
  end

  # ── The one system admin (QP4a-21) ──────────────────────────────────────────

  @doc """
  `mix aq.admin --to <email>`: hands the organisation's one admin row to an
  existing staff account, audited (`admin_handed`, the before and after
  holder). No route grants or revokes an admin. Refuses an unknown email
  (`{:error, :not_found}`), a customer's sign-in, and an organisation whose
  bootstrap invitation nobody has accepted yet (`{:error, :no_admin}`).
  Handing it to the holder changes nothing.
  """
  @spec hand_admin(Scope.t(), String.t(), DateTime.t()) :: {:ok, struct()} | {:error, term()}
  def hand_admin(%Scope{organisation: organisation} = scope, email, %DateTime{} = now) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    with %{} = admin <- Organisations.the_admin(organisation.id) || {:error, :no_admin},
         %{} = user <- Accounts.get_user_by_email(email) || {:error, :not_found},
         :ok <- staff_account(user) do
      hand_once(scope, admin, user, now)
    end
  end

  defp hand_once(_scope, %{user_id: id} = admin, %{id: id}, _now), do: {:ok, admin}

  defp hand_once(scope, admin, user, now) do
    case Repo.transaction(fn -> hand(scope, admin, user, now) end) do
      {:ok, {handed, events}} ->
        :ok = Core.Notifications.send_events(events)
        {:ok, handed}

      other ->
        other
    end
  end

  defp staff_account(user) do
    if Data.Customers.get_by_user(user.id), do: {:error, :customer}, else: :ok
  end

  defp hand(scope, admin, user, now) do
    {:ok, handed} = Organisations.hand_admin(admin, user.id, now)

    {:ok, _event} =
      Audit.record(scope, "admin_handed", handed,
        before: %{user_id: admin.user_id},
        after: %{user_id: user.id},
        now: now
      )

    # AQ-10B §5.1 A10: both people told (locked).
    old = Accounts.get_user(admin.user_id)
    new = Accounts.with_person(user)
    org = Scope.organisation_id(scope)

    events = [
      AccountNotices.security(new, org, {:admin_to, name_of(old)}, now),
      if(old,
        do: AccountNotices.security(old, org, {:admin_from, name_of(new)}, now),
        else: []
      )
    ]

    {Repo.preload(handed, [user: :person], force: true), events}
  end

  defp name_of(%{person: %{display_name: name}}), do: name
  defp name_of(_none), do: "The system admin"

  # ── People ──────────────────────────────────────────────────────────────────

  @doc """
  `GET /people?team_id&$where`: every staff person the caller may see — all
  of them for an admin, their own teams' for anyone else; `team_id` narrows
  to one team — with email, teams and roles, last signed in, and whether
  they are an admin. An admin in no team is still staff: an admin sees
  them, unless a team is asked for. `$where` is `Data.Filters.People`'s
  (`q`, `suspended`, `admin`).
  """
  @spec list_people(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_people(%Scope{organisation: organisation} = scope, params \\ %{}) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    team_id = Utils.presence(params["team_id"])

    with :ok <- Access.why_not(scope, :read_people, :people),
         visible = visible_team_ids(scope, team_id),
         with_admins? = Scope.admin?(scope) and is_nil(team_id),
         {:ok, users} <- Teams.people(organisation.id, visible, with_admins?, params["$where"]) do
      admins = organisation.id |> Organisations.list_admins() |> MapSet.new(& &1.user_id)
      memberships = visible |> Teams.memberships_in() |> Enum.group_by(& &1.user_id)

      people =
        users
        |> Enum.map(&person(&1, Map.get(memberships, &1.id, []), MapSet.member?(admins, &1.id)))
        |> Enum.sort_by(& &1.display_name)

      {:ok, people}
    end
  end

  defp visible_team_ids(scope, team_id) do
    all =
      if Scope.admin?(scope),
        do: Enum.map(Teams.list(scope.organisation.id), & &1.id),
        else: Scope.team_ids(scope)

    if team_id, do: Enum.filter(all, &(&1 == team_id)), else: all
  end

  defp person(user, memberships, admin?) do
    %{
      user_id: user.id,
      display_name: user.person.display_name,
      email: user.email,
      admin: admin?,
      is_admin: admin?,
      teams: for(m <- memberships, do: %{team_id: m.team_id, name: m.team.name, role: m.role}),
      last_signed_in_at: user.last_signed_in_at,
      suspended_at: user.suspended_at
    }
  end

  # ── The audit log ───────────────────────────────────────────────────────────

  @page 50

  @doc """
  `GET /org/audit?$where&cursor`, newest first, keyset. The system admin's
  alone (AQ-04A §8.5). `$where` is `Data.Filters.Audit`'s: `subject_kind`,
  `subject_id`, `actor`, `action`, `occurred_at` (local days in the
  organisation's zone). Answers `{:ok, events, next_cursor}`.
  """
  @spec list_audit(Scope.t(), map()) :: {:ok, [struct()], String.t() | nil} | {:error, term()}
  def list_audit(%Scope{organisation: organisation} = scope, params \\ %{}) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :read_audit, {:organisation, organisation}),
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      base = %{
        cursor: cursor,
        team_ids: if(Scope.admin?(scope), do: nil, else: Scope.team_ids(scope))
      }

      audit_page(scope, base, params["$where"])
    end
  end

  @doc """
  `GET /customers/:id/activity?$where&cursor` (AQ-04B QP4b-22): the audit
  rows about one customer — the customer's own and every row naming them —
  newest first, keyset, narrowed by the audit log's `$where`. **Every row
  for the system admin; a team lead, the rows of their teams** (a row
  naming one of the teams they lead); staff and the customer: not found.
  Answers `{:ok, events, next_cursor}`, the shape of `GET /org/audit`.
  """
  @spec customer_activity(Scope.t(), term(), map()) ::
          {:ok, [struct()], String.t() | nil} | {:error, term()}
  def customer_activity(%Scope{organisation: organisation} = scope, customer_id, params \\ %{}) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with %{} = customer <-
           Data.Customers.get(organisation.id, customer_id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :read_activity, {:customer, customer}),
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      led = for {id, :lead} <- scope.roles.teams, do: id

      base = %{
        customer_id: customer.id,
        cursor: cursor,
        team_ids: if(Scope.admin?(scope), do: nil, else: led)
      }

      audit_page(scope, base, params["$where"])
    end
  end

  defp audit_page(%Scope{organisation: organisation} = scope, base, where) do
    context = Data.Filters.context(scope, [])

    with {:ok, events} <- Data.Audit.list(organisation.id, base, where, context, @page + 1) do
      {page, more} = Enum.split(events, @page)
      {:ok, Labels.attach(page), if(more == [], do: nil, else: encode_cursor(List.last(page)))}
    end
  end

  defp encode_cursor(event),
    do: Base.url_encode64("#{DateTime.to_iso8601(event.occurred_at)}|#{event.id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [at, id] <- String.split(decoded, "|", parts: 2),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _invalid -> {:error, {:missing, :cursor}}
    end
  end
end
