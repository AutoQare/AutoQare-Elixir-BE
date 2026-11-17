defmodule Data.Imports do
  @moduledoc """
  Imports and their rows (AQ-12 §11.4), storage only: who may run one, the
  dry run's rules and the writes an import makes are `Core.Imports`'. The
  rows page by tab and row number (keyset), narrowed by
  `Data.Filters.ImportRows`; the undo's questions — is this lead, job,
  contact or company still only the import's? — are asked here as queries.
  """

  import Ecto.Query, warn: false

  alias Data.Audit.AuditEvent
  alias Data.Companies.Company
  alias Data.Contacts.{Contact, LeadContact}
  alias Data.Conversations.{Message, Participant}
  alias Data.Filters
  alias Data.Imports.{Import, Row}
  alias Data.Jobs.Job
  alias Data.Labels.LeadLabel
  alias Data.Leads.{Event, Lead, Note}
  alias Data.Meetings.Attendee
  alias Data.Repo
  alias Data.Tasks.Task

  @preload [:team, :media, created_by_user: :person]
  @batch 500

  # ── Imports ─────────────────────────────────────────────────────────────────

  @doc "An import of the organisation, with its team and maker; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Import.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Import |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "An import by id alone, for a background job (`nil` when it is gone)."
  @spec get_for_system(binary()) :: Import.t() | nil
  def get_for_system(id), do: Import |> Repo.get(id) |> load()

  @doc "The import again, fresh."
  @spec reload(Import.t()) :: Import.t()
  def reload(%Import{} = import), do: Import |> Repo.get!(import.id) |> load()

  @doc "The imports of `team_ids`, newest first."
  @spec list(binary(), [binary()]) :: [Import.t()]
  def list(organisation_id, team_ids) do
    from(i in Import,
      where: i.organisation_id == ^organisation_id and i.team_id in ^team_ids,
      order_by: [desc: i.inserted_at, desc: i.id],
      preload: ^@preload
    )
    |> Repo.all()
  end

  defp load(nil), do: nil
  defp load(import), do: Repo.preload(import, @preload, force: true)

  @spec create(map()) :: {:ok, Import.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, import} <- %Import{} |> Import.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(import)}
  end

  @spec update(Import.t(), map()) :: {:ok, Import.t()} | {:error, Ecto.Changeset.t()}
  def update(%Import{} = import, attrs) do
    with {:ok, updated} <- import |> Import.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "The import locked for its transaction (`FOR UPDATE`), so two steps never cross."
  @spec lock(Import.t()) :: Import.t()
  def lock(%Import{id: id}),
    do: from(i in Import, where: i.id == ^id, lock: "FOR UPDATE") |> Repo.one!() |> load()

  # ── Rows ────────────────────────────────────────────────────────────────────

  @doc """
  The rows read from the file, written in batches: each `%{tab, row_number,
  cells}`, every earlier row of the import deleted first (a re-read).
  """
  @spec put_rows(Import.t(), [map()], DateTime.t()) :: :ok
  def put_rows(%Import{id: import_id}, rows, %DateTime{} = now) do
    Repo.delete_all(from(r in Row, where: r.import_id == ^import_id))

    rows
    |> Enum.map(fn row ->
      %{
        id: Uniq.UUID.uuid7(),
        import_id: import_id,
        tab: row.tab,
        row_number: row.row_number,
        cells: row.cells,
        values: %{},
        reasons: [],
        created: %{},
        replaced: %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(@batch)
    |> Enum.each(&Repo.insert_all(Row, &1))
  end

  @doc "Every row of an import, by tab and row number (`result` narrows)."
  @spec rows(binary(), keyword()) :: [Row.t()]
  def rows(import_id, opts \\ []) do
    query =
      from(r in Row, where: r.import_id == ^import_id, order_by: [asc: r.tab, asc: r.row_number])

    query =
      case Keyword.get(opts, :results) do
        nil -> query
        results -> where(query, [r], r.result in ^results)
      end

    Repo.all(query)
  end

  @doc """
  A page of an import's rows, by tab and row number: `$where` through
  `Data.Filters.ImportRows`, `after` the last `{tab, row_number}` seen.
  `{:ok, rows}` (one more than `limit` when another page follows) or the
  422's refusal.
  """
  @spec rows_page(binary(), term(), {String.t(), integer()} | nil, pos_integer()) ::
          {:ok, [Row.t()]} | {:error, term()}
  def rows_page(import_id, where, after_key, limit) do
    base = from(r in Row, where: r.import_id == ^import_id)

    with {:ok, query} <- Filters.where(base, Filters.ImportRows, where, %{}) do
      query =
        case after_key do
          nil ->
            query

          {tab, n} ->
            where(query, [r], r.tab > ^tab or (r.tab == ^tab and r.row_number > ^n))
        end

      {:ok,
       query
       |> order_by([r], asc: r.tab, asc: r.row_number)
       |> limit(^(limit + 1))
       |> preload(:job)
       |> Repo.all()}
    end
  end

  @doc "A row of the import; `nil` for a malformed id or another import's row."
  @spec get_row(binary(), term()) :: Row.t() | nil
  def get_row(import_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Row, id: uuid, import_id: import_id)
      :error -> nil
    end
  end

  def get_row(_import_id, _id), do: nil

  @doc "A row's change; answers it with its job."
  @spec update_row(Row.t(), map()) :: {:ok, Row.t()} | {:error, Ecto.Changeset.t()}
  def update_row(%Row{} = row, attrs) do
    with {:ok, row} <- row |> Row.changeset(attrs) |> Repo.update(),
         do: {:ok, Repo.preload(row, :job, force: true)}
  end

  @doc "How many rows of each result: `%{\"new\" => n, …}` (a row not checked yet counts nowhere)."
  @spec result_counts(binary()) :: %{String.t() => non_neg_integer()}
  def result_counts(import_id) do
    from(r in Row,
      where: r.import_id == ^import_id and not is_nil(r.result),
      group_by: r.result,
      select: {r.result, count(r.id)}
    )
    |> Repo.all()
    |> Map.new(fn {result, n} -> {Atom.to_string(result), n} end)
  end

  # ── What an undo asks ───────────────────────────────────────────────────────

  @doc """
  Whether a lead an import made has been touched by anything but the
  import: an event not the import's, a note, a task, a label, or an audit
  row other than its making.
  """
  @spec lead_touched?(binary()) :: boolean()
  def lead_touched?(lead_id) do
    exists?(from(e in Event, where: e.lead_id == ^lead_id and e.actor_kind != :import)) or
      exists?(from(n in Note, where: n.lead_id == ^lead_id)) or
      exists?(from(t in Task, where: t.lead_id == ^lead_id)) or
      exists?(from(l in LeadLabel, where: l.lead_id == ^lead_id)) or
      audited?("leads", lead_id)
  end

  @doc "Whether a job has a lead besides `except`, or was changed by anything but an import."
  @spec job_held?(binary(), [binary()]) :: boolean()
  def job_held?(job_id, except) do
    exists?(from(l in Lead, where: l.job_id == ^job_id and l.id not in ^except)) or
      audited?("jobs", job_id)
  end

  @doc "Whether anything but the import links a contact: a lead, a conversation, a meeting, a message."
  @spec contact_held?(binary()) :: boolean()
  def contact_held?(contact_id) do
    exists?(from(l in LeadContact, where: l.contact_id == ^contact_id)) or
      exists?(from(p in Participant, where: p.contact_id == ^contact_id)) or
      exists?(from(a in Attendee, where: a.contact_id == ^contact_id)) or
      exists?(from(m in Message, where: m.from_contact_id == ^contact_id))
  end

  @doc "Whether a company still has a job or a contact."
  @spec company_held?(binary()) :: boolean()
  def company_held?(company_id) do
    exists?(from(j in Job, where: j.company_id == ^company_id)) or
      exists?(from(c in Contact, where: c.company_id == ^company_id))
  end

  @doc "Deletes a contact (its handles cascade)."
  @spec delete_contact(binary()) :: :ok
  def delete_contact(id) do
    Repo.delete_all(from(c in Contact, where: c.id == ^id))
    :ok
  end

  @doc "Deletes a company (its observations cascade)."
  @spec delete_company(binary()) :: :ok
  def delete_company(id) do
    Repo.delete_all(from(c in Company, where: c.id == ^id))
    :ok
  end

  # An audit row on the subject other than its making or an import's fill.
  defp audited?(kind, id) do
    exists?(
      from(a in AuditEvent,
        where:
          a.subject_kind == ^kind and a.subject_id == ^id and
            a.action not in ["created", "import_filled"]
      )
    )
  end

  defp exists?(query), do: Repo.exists?(query)
end
