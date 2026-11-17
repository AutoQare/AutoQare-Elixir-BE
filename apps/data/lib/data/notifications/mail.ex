defmodule Data.Notifications.Mail do
  @moduledoc """
  What an email needs beyond its notification row (AQ-10B §7, §11.4),
  storage only, read by `notifire`: the organisation's name and footer
  settings, the subject's facts (a lead's job, company, profile and
  stage; a task's or an approval's title and due time), and who a
  customer's reply reaches (the profile's first owner, QP10b-10).
  """

  import Ecto.Query, warn: false

  alias Data.Customers.{Customer, Profile, ProfileMember}
  alias Data.Organisations
  alias Data.Organisations.{OrgAdmin, Organisation}
  alias Data.Repo
  alias Data.Teams.{Team, TeamMember}

  @doc "`%{id, name, help_email, postal_address}` of an organisation, or `nil`."
  @spec organisation(binary() | nil) :: map() | nil
  def organisation(nil), do: nil

  def organisation(id) do
    case Organisations.get(id) do
      nil ->
        nil

      org ->
        settings = Organisations.get_settings(org.id)

        %{
          id: org.id,
          name: org.name,
          help_email: settings.help_email,
          postal_address: settings.postal_address
        }
    end
  end

  @doc """
  The organisation an account belongs to (its admin row, a team, or its
  customer row), as `organisation/1`; the only organisation when the
  account has none yet.
  """
  @spec organisation_of_user(binary()) :: map() | nil
  def organisation_of_user(user_id) do
    admin = from(a in OrgAdmin, where: a.user_id == ^user_id, select: a.organisation_id)

    team =
      from(m in TeamMember,
        join: t in Team,
        on: t.id == m.team_id,
        where: m.user_id == ^user_id,
        select: t.organisation_id
      )

    customer = from(c in Customer, where: c.user_id == ^user_id, select: c.organisation_id)

    id =
      Repo.one(from(q in subquery(admin), limit: 1, select: q.organisation_id)) ||
        Repo.one(from(q in subquery(team), limit: 1, select: q.organisation_id)) ||
        Repo.one(from(q in subquery(customer), limit: 1, select: q.organisation_id)) ||
        Repo.one(from(o in Organisation, order_by: o.inserted_at, limit: 1, select: o.id))

    organisation(id)
  end

  @doc "A lead with its job, company, profile, customer and stage, or `nil`."
  @spec lead(binary(), binary() | nil) :: struct() | nil
  def lead(_organisation_id, nil), do: nil
  def lead(organisation_id, lead_id), do: Data.Leads.get(organisation_id, lead_id)

  @doc "`%{title, due_on, due_at}` of a task, or `nil`."
  @spec task(binary() | nil) :: map() | nil
  def task(nil), do: nil

  def task(task_id) do
    from(t in Data.Tasks.Task,
      where: t.id == ^task_id,
      select: %{title: t.title, due_on: t.due_on, due_at: t.due_at}
    )
    |> Repo.one()
  end

  @doc "`%{title, due_at, lead_id, customer_id}` of an approval, or `nil`."
  @spec approval(binary() | nil) :: map() | nil
  def approval(nil), do: nil

  def approval(approval_id) do
    from(a in Data.Approvals.Approval,
      where: a.id == ^approval_id,
      select: %{title: a.title, due_at: a.due_at, lead_id: a.lead_id, customer_id: a.customer_id}
    )
    |> Repo.one()
  end

  @doc """
  Who a customer's reply reaches (QP10b-10): the first owner of the lead's
  profile, else of the customer's first profile, as `{name, email}`; `nil`
  when nobody owns them.
  """
  @spec reply_to(binary() | nil, binary() | nil) :: {String.t(), String.t()} | nil
  def reply_to(nil, nil), do: nil

  def reply_to(customer_id, lead_id) do
    profile_ids =
      case lead_id &&
             Repo.one(from(l in Data.Leads.Lead, where: l.id == ^lead_id, select: l.profile_id)) do
        nil ->
          from(p in Profile,
            where: p.customer_id == ^customer_id and is_nil(p.archived_at),
            order_by: [asc: p.inserted_at],
            select: p.id
          )
          |> Repo.all()

        profile_id ->
          [profile_id]
      end

    from(m in ProfileMember,
      join: u in assoc(m, :user),
      join: p in assoc(u, :person),
      where: m.profile_id in ^profile_ids and is_nil(u.suspended_at),
      order_by: [asc: m.since_on, asc: m.id],
      limit: 1,
      select: {p.display_name, u.email}
    )
    |> Repo.one()
  end

  @doc "The customer row of a customer with no login, by id: the mail's addressee."
  @spec customer(binary()) :: Customer.t() | nil
  def customer(customer_id), do: Repo.get(Customer, customer_id)

  @doc "The customer row an account holds, or `nil` (staff)."
  @spec customer_of_user(binary()) :: Customer.t() | nil
  def customer_of_user(user_id), do: Repo.get_by(Customer, user_id: user_id)
end
