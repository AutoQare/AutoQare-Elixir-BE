defmodule Data.Behaviour do
  @moduledoc """
  Observations and the hour counts (AQ-10 §5, §11.4). Storage only: what
  a pattern says is `Core.Behaviour.Pattern`'s, who may read it
  `Core.Access`'s, the rest `Core.Behaviour`'s.

  A **subject** is `{:company, id}` or `{:contact, id}`. Every read is
  bound to a subject the context has already found in the caller's
  organisation, or to an organisation (the sweep's and the list's).
  """

  import Ecto.Query, warn: false

  alias Data.Behaviour.{Observation, SubjectHour, Watch}
  alias Data.Repo

  @type subject :: {:company | :contact, binary()}

  @groups %{
    seen_online: :active,
    last_active_reported: :active,
    viewed_proposal: :active,
    viewed_profile: :active,
    message_read: :active,
    job_posted: :posted,
    job_reposted: :posted,
    replied: :replied
  }
  @active ~w(seen_online last_active_reported viewed_proposal viewed_profile message_read)
  @active_kinds Enum.map(@active, &String.to_atom/1)
  @posted_kinds [:job_posted, :job_reposted]

  @doc "The hour group an observation kind counts in (AQ-10 §11.4)."
  @spec group(atom()) :: atom()
  def group(kind), do: Map.fetch!(@groups, kind)

  @doc "The kinds of the `active` group, as strings."
  def active_kinds, do: @active

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc """
  Inserts the observation unless one of its unique keys is taken — the
  same job fact, the same reply, the same `request_id` — answering
  `{:ok, observation}`, `{:ok, :exists}`, or the changeset's error.
  """
  @spec insert_observation(map()) ::
          {:ok, Observation.t() | :exists} | {:error, Ecto.Changeset.t()}
  def insert_observation(attrs) do
    changeset = Observation.changeset(%Observation{}, attrs)

    with {:ok, valid} <- Ecto.Changeset.apply_action(changeset, :insert) do
      row =
        valid
        |> Map.take(Observation.__schema__(:fields))
        |> Map.put(:id, Uniq.UUID.uuid7())

      case Repo.insert_all(Observation, [row], on_conflict: :nothing, returning: true) do
        {1, [inserted]} -> {:ok, inserted}
        {0, []} -> {:ok, :exists}
      end
    end
  end

  @doc """
  +1 in the subject's cell for the observation's group, at the UTC weekday
  and hour of its `active_at`.
  """
  @spec bump_hours(Observation.t()) :: :ok
  def bump_hours(%Observation{} = o) do
    at = o.active_at
    column = if o.company_id, do: :company_id, else: :contact_id

    row = %{
      id: Uniq.UUID.uuid7(),
      organisation_id: o.organisation_id,
      company_id: o.company_id,
      contact_id: o.contact_id,
      kind_group: group(o.kind),
      weekday: Date.day_of_week(DateTime.to_date(at)),
      hour: at.hour,
      count: 1
    }

    {1, _rows} =
      Repo.insert_all(SubjectHour, [row],
        on_conflict: [inc: [count: 1]],
        conflict_target:
          {:unsafe_fragment, "(#{column}, kind_group, weekday, hour) WHERE #{column} IS NOT NULL"}
      )

    :ok
  end

  # ── Reads of one subject, or several ────────────────────────────────────────

  @doc "The observation the extension's `request_id` made in the organisation, or `nil`."
  @spec by_request(binary(), String.t()) :: Observation.t() | nil
  def by_request(organisation_id, request_id),
    do: Repo.get_by(Observation, organisation_id: organisation_id, request_id: request_id)

  @doc "Whether a job has written its `job_reposted` already."
  @spec reposted?(binary()) :: boolean()
  def reposted?(job_id),
    do:
      Repo.exists?(from(o in Observation, where: o.job_id == ^job_id and o.kind == :job_reposted))

  @doc "An observation of the organisation, or `nil`."
  @spec get(binary(), term()) :: Observation.t() | nil
  def get(organisation_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Observation, id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  @doc """
  The facts a pattern reads, for each subject: `%{subject => %{hours,
  last_active_at, active_days, delays, posted_recent, seen}}` — the hour
  cells (`{group, weekday, hour, count}`), the newest `active_at` of the
  active group, the distinct UTC days active observations still kept fall
  on, the last 20 reply delays (newest first), the posted observations
  since `since`, and every observation ever counted.
  """
  @spec facts([subject()], DateTime.t()) :: %{subject() => map()}
  def facts([], _since), do: %{}

  def facts(subjects, %DateTime{} = since) do
    {companies, contacts} = split(subjects)

    empty = %{
      hours: [],
      last_active_at: nil,
      active_days: 0,
      delays: [],
      posted_recent: 0,
      seen: 0
    }

    base = Map.new(subjects, &{&1, empty})

    base
    |> merge_list(hours(companies, contacts), :hours)
    |> merge_one(latest_active(companies, contacts), :last_active_at)
    |> merge_one(active_days(companies, contacts), :active_days)
    |> merge_list(delays(contacts), :delays)
    |> merge_one(posted_since(companies, contacts, since), :posted_recent)
    |> Map.new(fn {s, f} ->
      {s, Map.put(f, :seen, Enum.reduce(f.hours, 0, &(&2 + elem(&1, 3))))}
    end)
  end

  defp split(subjects) do
    {for({:company, id} <- subjects, do: id), for({:contact, id} <- subjects, do: id)}
  end

  defp merge_list(base, rows, key) do
    Enum.reduce(rows, base, fn {subject, value}, acc ->
      if Map.has_key?(acc, subject),
        do: update_in(acc, [subject, key], &(&1 ++ [value])),
        else: acc
    end)
  end

  defp merge_one(base, rows, key) do
    Enum.reduce(rows, base, fn {subject, value}, acc ->
      if Map.has_key?(acc, subject), do: put_in(acc, [subject, key], value), else: acc
    end)
  end

  defp subject_of(company_id, contact_id),
    do: if(company_id, do: {:company, company_id}, else: {:contact, contact_id})

  defp for_subjects(query, companies, contacts) do
    where(query, [r], r.company_id in ^companies or r.contact_id in ^contacts)
  end

  defp hours(companies, contacts) do
    from(h in SubjectHour,
      where: h.count > 0,
      order_by: [asc: h.kind_group, asc: h.weekday, asc: h.hour],
      select: {h.company_id, h.contact_id, h.kind_group, h.weekday, h.hour, h.count}
    )
    |> for_subjects(companies, contacts)
    |> Repo.all()
    |> Enum.map(fn {co, ct, g, d, h, n} -> {subject_of(co, ct), {g, d, h, n}} end)
  end

  defp active_query(companies, contacts) do
    from(o in Observation, where: o.kind in ^@active_kinds)
    |> for_subjects(companies, contacts)
  end

  defp latest_active(companies, contacts) do
    companies
    |> active_query(contacts)
    |> group_by([o], [o.company_id, o.contact_id])
    |> select([o], {o.company_id, o.contact_id, max(o.active_at)})
    |> Repo.all()
    |> Enum.map(fn {co, ct, at} -> {subject_of(co, ct), at} end)
  end

  defp active_days(companies, contacts) do
    companies
    |> active_query(contacts)
    |> group_by([o], [o.company_id, o.contact_id])
    |> select(
      [o],
      {o.company_id, o.contact_id, count(fragment("DISTINCT (?)::date", o.active_at))}
    )
    |> Repo.all()
    |> Enum.map(fn {co, ct, n} -> {subject_of(co, ct), n} end)
  end

  defp delays([]), do: []

  defp delays(contacts) do
    ranked =
      from(o in Observation,
        where: o.contact_id in ^contacts and o.kind == :replied and not is_nil(o.reply_delay_s),
        select: %{
          contact_id: o.contact_id,
          delay: o.reply_delay_s,
          active_at: o.active_at,
          rank: over(row_number(), :by_contact)
        },
        windows: [by_contact: [partition_by: o.contact_id, order_by: [desc: o.active_at]]]
      )

    from(r in subquery(ranked),
      where: r.rank <= 20,
      order_by: [asc: r.contact_id, desc: r.active_at],
      select: {r.contact_id, r.delay}
    )
    |> Repo.all()
    |> Enum.map(fn {ct, delay} -> {{:contact, ct}, delay} end)
  end

  defp posted_since(companies, contacts, since) do
    from(o in Observation,
      where: o.kind in ^@posted_kinds and o.active_at >= ^since,
      group_by: [o.company_id, o.contact_id],
      select: {o.company_id, o.contact_id, count(o.id)}
    )
    |> for_subjects(companies, contacts)
    |> Repo.all()
    |> Enum.map(fn {co, ct, n} -> {subject_of(co, ct), n} end)
  end

  @doc """
  The jobs of each company the extension first saw on the day they were
  posted, as `first_seen_at` instants: the posting hour's evidence
  (AQ-10 §7). The day is the organisation's, `zone`. `%{company_id =>
  [instant]}`.
  """
  @spec same_day_first_seen([binary()], String.t()) :: %{binary() => [DateTime.t()]}
  def same_day_first_seen([], _zone), do: %{}

  def same_day_first_seen(company_ids, zone) do
    from(j in Data.Jobs.Job,
      where:
        j.company_id in ^company_ids and j.origin == :extension and not is_nil(j.posted_on) and
          fragment("(? AT TIME ZONE ?)::date", j.first_seen_at, ^zone) == j.posted_on,
      select: {j.company_id, j.first_seen_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  A subject's observations, newest `active_at` first, after the keyset
  `{active_at, id}`; `limit + 1` rows so the caller knows there is more.
  With the observer, the job and the message's conversation.
  """
  @spec page(subject(), {DateTime.t(), binary()} | nil, pos_integer()) :: [Observation.t()]
  def page(subject, after_key, limit) do
    from(o in Observation,
      order_by: [desc: o.active_at, desc: o.id],
      limit: ^(limit + 1),
      preload: [:job, :message, observer_user: :person]
    )
    |> of(subject)
    |> after_key(after_key)
    |> Repo.all()
  end

  defp after_key(query, nil), do: query

  defp after_key(query, {at, id}),
    do: where(query, [o], o.active_at < ^at or (o.active_at == ^at and o.id < ^id))

  defp of(query, {:company, id}), do: where(query, [r], r.company_id == ^id)
  defp of(query, {:contact, id}), do: where(query, [r], r.contact_id == ^id)

  @doc """
  The contact behind a conversation (AQ-10 §11.4): the sender of its
  latest inbound message, else its only participant; `nil` otherwise.
  """
  @spec conversation_contact(binary()) :: binary() | nil
  def conversation_contact(conversation_id) do
    sender =
      from(m in Data.Conversations.Message,
        where:
          m.conversation_id == ^conversation_id and m.direction == :in and
            not is_nil(m.from_contact_id) and is_nil(m.deleted_at),
        order_by: [desc: m.sent_at, desc: m.id],
        limit: 1,
        select: m.from_contact_id
      )
      |> Repo.one()

    sender ||
      case Repo.all(
             from(p in Data.Conversations.Participant,
               where: p.conversation_id == ^conversation_id,
               select: p.contact_id
             )
           ) do
        [one] -> one
        _none_or_several -> nil
      end
  end

  @doc """
  The message just before `message` in its conversation, by when it was
  sent: a chat's parent, where a captured thread names none.
  """
  @spec previous_message(map()) :: map() | nil
  def previous_message(message) do
    from(m in Data.Conversations.Message,
      where:
        m.conversation_id == ^message.conversation_id and m.id != ^message.id and
          not m.is_internal and is_nil(m.deleted_at) and
          (m.sent_at < ^message.sent_at or (m.sent_at == ^message.sent_at and m.id < ^message.id)),
      order_by: [desc: m.sent_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  # ── Who touches a subject ───────────────────────────────────────────────────

  @doc """
  The teams that touch a subject (AQ-10 §4): for a company, the teams of
  its jobs (and so its leads) and of conversations with one of its
  contacts; for a contact, the teams of its leads and conversations.
  """
  @spec team_ids(subject()) :: [binary()]
  def team_ids({:company, id}) do
    {:ok, uuid} = Ecto.UUID.dump(id)

    sql(
      "SELECT j.team_id FROM jobs j WHERE j.company_id = $1 " <>
        "UNION SELECT c.team_id FROM conversations c " <>
        "JOIN conversation_participants p ON p.conversation_id = c.id " <>
        "JOIN contacts k ON k.id = p.contact_id WHERE k.company_id = $1",
      [uuid]
    )
  end

  def team_ids({:contact, id}) do
    {:ok, uuid} = Ecto.UUID.dump(id)

    sql(
      "SELECT j.team_id FROM lead_contacts lc JOIN leads l ON l.id = lc.lead_id " <>
        "JOIN jobs j ON j.id = l.job_id WHERE lc.contact_id = $1 " <>
        "UNION SELECT c.team_id FROM conversation_participants p " <>
        "JOIN conversations c ON c.id = p.conversation_id WHERE p.contact_id = $1",
      [uuid]
    )
  end

  defp sql(query, params) do
    %{rows: rows} = Repo.query!(query, params)
    rows |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end) |> Enum.uniq()
  end

  # ── Forget and the sweep ────────────────────────────────────────────────────

  @doc "Deletes a contact's observations, hour counts and watches. Answers what went."
  @spec forget_contact(binary()) :: %{
          observations: integer(),
          hours: integer(),
          watches: integer()
        }
  def forget_contact(contact_id) do
    {observations, _} =
      Repo.delete_all(from(o in Observation, where: o.contact_id == ^contact_id))

    {hours, _} = Repo.delete_all(from(h in SubjectHour, where: h.contact_id == ^contact_id))
    {watches, _} = Repo.delete_all(from(w in Watch, where: w.contact_id == ^contact_id))
    %{observations: observations, hours: hours, watches: watches}
  end

  @doc """
  The sweep (AQ-10 §9): deletes the organisation's observations seen
  before `cutoff`. `subject_hours` stays. Answers how many went.
  """
  @spec delete_seen_before(binary(), DateTime.t()) :: non_neg_integer()
  def delete_seen_before(organisation_id, %DateTime{} = cutoff) do
    {n, _rows} =
      Repo.delete_all(
        from(o in Observation,
          where: o.organisation_id == ^organisation_id and o.observed_at < ^cutoff
        )
      )

    n
  end

  @doc "Every organisation's id with its observation retention in days (the sweep's system read)."
  @spec retention_for_system() :: [{binary(), pos_integer()}]
  def retention_for_system do
    from(o in Data.Organisations.Organisation,
      left_join: s in Data.Organisations.OrganisationSettings,
      on: s.organisation_id == o.id,
      order_by: o.inserted_at,
      select: {o.id, coalesce(s.observation_retention_days, 180)}
    )
    |> Repo.all()
  end
end
