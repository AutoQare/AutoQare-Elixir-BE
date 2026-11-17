defmodule Data.Behaviour.Subjects do
  @moduledoc """
  The Behaviour page's reads (AQ-10 §11.4): the subjects a team touches
  with anything counted, newest `last_seen` first; their open leads; their
  watchers. Storage only, bound to an organisation and the teams the
  context passes (`:all` for the system admin with no team named).
  """

  import Ecto.Query, warn: false

  alias Data.Behaviour.{SubjectHour, Watch}
  alias Data.Companies.Company
  alias Data.Contacts.{Contact, LeadContact}
  alias Data.Conversations.{Conversation, Participant}
  alias Data.Jobs.Job
  alias Data.Leads.Lead
  alias Data.Repo

  @active ~w(seen_online last_active_reported viewed_proposal viewed_profile message_read)
  @open_states [:todo, :in_progress, :on_hold]

  @doc """
  `GET /behaviour`'s rows: `%{kind, id, name, company_id, company_name,
  last_seen}`. `where` is the list's `$where` (`Data.Filters.Behaviour`:
  `q`, `kind`, `watched`), run on each part with `context` naming it;
  `opts` `offset` and `limit` (`limit + 1` rows come back, so the caller
  knows there is more). `{:ok, rows}`, or the 422 `invalid_filter`.
  """
  @spec list(binary(), [binary()] | :all, term(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list(organisation_id, team_ids, where, context, opts) do
    with {:ok, companies} <- part(companies(organisation_id, team_ids), :company, where, context),
         {:ok, contacts} <- part(contacts(organisation_id, team_ids), :contact, where, context) do
      rows =
        from(s in subquery(union_all(companies, ^contacts)),
          order_by: [desc_nulls_last: s.last_seen, asc: s.name, asc: s.id],
          offset: ^(opts[:offset] || 0),
          limit: ^(opts[:limit] + 1)
        )
        |> Repo.all()
        |> Enum.map(fn row -> %{row | kind: String.to_existing_atom(row.kind)} end)

      {:ok, rows}
    end
  end

  defp part(query, part, where, context),
    do: Data.Filters.where(query, Data.Filters.Behaviour, where, Map.put(context, :part, part))

  defp companies(org, team_ids) do
    from(c in Company,
      as: :subject,
      where: c.organisation_id == ^org,
      where: exists(from(h in SubjectHour, where: h.company_id == parent_as(:subject).id)),
      select: %{
        kind: type(^"company", :string),
        id: c.id,
        name: c.name,
        company_id: type(^nil, :binary_id),
        company_name: type(^nil, :string),
        last_seen:
          fragment(
            "(SELECT max(o.active_at) FROM observations o WHERE o.company_id = ? AND o.kind = ANY(?))",
            c.id,
            ^@active
          )
      }
    )
    |> company_touch(team_ids)
  end

  defp contacts(org, team_ids) do
    from(c in Contact,
      as: :subject,
      left_join: co in assoc(c, :company),
      where: c.organisation_id == ^org,
      where: exists(from(h in SubjectHour, where: h.contact_id == parent_as(:subject).id)),
      select: %{
        kind: type(^"contact", :string),
        id: c.id,
        name: c.name,
        company_id: co.id,
        company_name: co.name,
        last_seen:
          fragment(
            "(SELECT max(o.active_at) FROM observations o WHERE o.contact_id = ? AND o.kind = ANY(?))",
            c.id,
            ^@active
          )
      }
    )
    |> contact_touch(team_ids)
  end

  # A company on the teams' jobs (and so their leads), or on their
  # conversations through one of its contacts.
  defp company_touch(query, :all), do: query

  defp company_touch(query, team_ids) do
    jobs =
      from(j in Job, where: j.company_id == parent_as(:subject).id and j.team_id in ^team_ids)

    talks =
      from(cv in Conversation,
        join: p in Participant,
        on: p.conversation_id == cv.id,
        join: k in Contact,
        on: k.id == p.contact_id,
        where: k.company_id == parent_as(:subject).id and cv.team_id in ^team_ids
      )

    where(query, [], exists(jobs) or exists(talks))
  end

  # A contact on the teams' leads or conversations.
  defp contact_touch(query, :all), do: query

  defp contact_touch(query, team_ids) do
    leads =
      from(lc in LeadContact,
        join: l in Lead,
        on: l.id == lc.lead_id,
        join: j in Job,
        on: j.id == l.job_id,
        where: lc.contact_id == parent_as(:subject).id and j.team_id in ^team_ids
      )

    talks =
      from(p in Participant,
        join: cv in Conversation,
        on: cv.id == p.conversation_id,
        where: p.contact_id == parent_as(:subject).id and cv.team_id in ^team_ids
      )

    where(query, [], exists(leads) or exists(talks))
  end

  @doc """
  The open leads (live, not done) of each subject in `team_ids` (`:all`
  for every team): a company's on its jobs, a contact's through
  `lead_contacts`. `%{subject => count}`.
  """
  @spec open_leads([Data.Behaviour.subject()], [binary()] | :all) :: map()
  def open_leads([], _team_ids), do: %{}

  def open_leads(subjects, team_ids) do
    companies = for {:company, id} <- subjects, do: id
    contacts = for {:contact, id} <- subjects, do: id

    by_company =
      from(l in Lead,
        join: j in assoc(l, :job),
        where: j.company_id in ^companies and is_nil(l.archived_at) and l.state in ^@open_states,
        group_by: j.company_id,
        select: {j.company_id, count(l.id)}
      )
      |> lead_teams(team_ids)
      |> Repo.all()
      |> Enum.map(fn {id, n} -> {{:company, id}, n} end)

    by_contact =
      from(l in Lead,
        join: j in assoc(l, :job),
        join: lc in LeadContact,
        on: lc.lead_id == l.id,
        where: lc.contact_id in ^contacts and is_nil(l.archived_at) and l.state in ^@open_states,
        group_by: lc.contact_id,
        select: {lc.contact_id, count(l.id)}
      )
      |> lead_teams(team_ids)
      |> Repo.all()
      |> Enum.map(fn {id, n} -> {{:contact, id}, n} end)

    Map.new(by_company ++ by_contact)
  end

  defp lead_teams(query, :all), do: query
  defp lead_teams(query, team_ids), do: where(query, [_l, j], j.team_id in ^team_ids)

  @doc "The watchers of each subject, `%{subject => [%{id, name}]}`, by name."
  @spec watchers([Data.Behaviour.subject()]) :: map()
  def watchers([]), do: %{}

  def watchers(subjects) do
    companies = for {:company, id} <- subjects, do: id
    contacts = for {:contact, id} <- subjects, do: id

    from(w in Watch,
      join: u in assoc(w, :user),
      join: p in assoc(u, :person),
      where: w.company_id in ^companies or w.contact_id in ^contacts,
      order_by: [asc: p.display_name, asc: u.id],
      select: {w.company_id, w.contact_id, u.id, p.display_name}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {co, ct, _id, _name} -> if co, do: {:company, co}, else: {:contact, ct} end,
      fn {_co, _ct, id, name} -> %{id: id, name: name} end
    )
    |> Map.new(fn {subject, people} -> {subject, Enum.uniq_by(people, & &1.id)} end)
  end

  @doc """
  A company's newest jobs in `team_ids` (`:all` for every team), by when
  they were first seen, at most `limit`, with what P3's row shows.
  """
  @spec company_jobs(binary(), [binary()] | :all, pos_integer()) :: [Job.t()]
  def company_jobs(company_id, team_ids, limit) do
    from(j in Job,
      where: j.company_id == ^company_id,
      order_by: [desc: j.first_seen_at, desc: j.id],
      limit: ^limit,
      preload: ^Data.Jobs.base_preload()
    )
    |> then(&if(team_ids == :all, do: &1, else: where(&1, [j], j.team_id in ^team_ids)))
    |> Repo.all()
  end
end
