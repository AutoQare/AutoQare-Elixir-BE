defmodule Core.Behaviour.Sources do
  @moduledoc """
  The writers of AQ-10 §6.1, each inside the transaction of the change
  that caused it, each through `Core.Behaviour.observe/2`:

  | Writer | When | Observation |
  |---|---|---|
  | `Core.Jobs.insert_new/5` (a job by hand, a capture, a lead with a job) | a job new to the pool | `job_posted`, or `job_reposted` when it says so · its company · `active_at` the posted day at noon in the organisation's zone, else `first_seen_at` · `source: job` |
  | `Core.Ingest.Extension.Pool.refresh/4` | a capture first reads a pool job as reposted (no `job_reposted` of the job yet) | `job_reposted` · its company · the day the page names at noon, else now |
  | `Core.Jobs.Capture` | a signals row whose `client_last_viewed_at` moved | `last_active_reported` · the job's company · `active_at` that time · `source: extension` |
  | `Core.Conversations.Record.message/4` (every landing: by hand, `.eml`, forwarded, captured) | an inbound message from a contact whose parent is outbound | `replied` · the sender · `reply_delay_s` · `active_at` its `sent_at` |

  **A chat has no tree**: a captured message names no parent, so its
  parent is the message just before it in the conversation. A job with no
  company, or a message from no contact, has no subject and writes
  nothing. Unique keys make a second capture of the same fact write
  nothing.
  """

  alias Core.Behaviour
  alias Data.Behaviour, as: Store
  alias Data.Conversations
  alias Data.Scope

  @doc "A job new to the pool: `job_posted` (or `job_reposted`) for its company."
  @spec job_new(Scope.t(), map(), DateTime.t()) :: :ok
  def job_new(%Scope{} = scope, %{company_id: company_id} = job, %DateTime{} = now)
      when is_binary(company_id) do
    observe(scope, %{
      company_id: company_id,
      kind: if(job.is_reposted, do: :job_reposted, else: :job_posted),
      source: :job,
      observed_at: now,
      active_at: noon(job.posted_on, Core.Tasks.zone(scope)) || job.first_seen_at || now,
      job_id: job.id,
      now: now
    })
  end

  def job_new(_scope, _job, _now), do: :ok

  @doc """
  A pool job seen again by a capture (`posted` the capture's
  `%{"posted_on", "is_reposted"}`): `job_reposted` the first time it reads
  as reposted.
  """
  @spec job_seen(Scope.t(), map(), map(), DateTime.t()) :: :ok
  def job_seen(
        %Scope{} = scope,
        %{company_id: company_id} = job,
        %{"is_reposted" => true} = posted,
        now
      )
      when is_binary(company_id) do
    if Store.reposted?(job.id) do
      :ok
    else
      observe(scope, %{
        company_id: company_id,
        kind: :job_reposted,
        source: :job,
        observed_at: now,
        active_at: noon(posted["posted_on"], Core.Tasks.zone(scope)) || now,
        job_id: job.id,
        now: now
      })
    end
  end

  def job_seen(_scope, _job, _posted, _now), do: :ok

  @doc "Upwork's *last viewed* moved on a job: `last_active_reported` for its company."
  @spec last_viewed(Scope.t(), map(), DateTime.t(), DateTime.t()) :: :ok
  def last_viewed(%Scope{} = scope, %{company_id: company_id} = job, %DateTime{} = at, now)
      when is_binary(company_id) do
    observe(scope, %{
      company_id: company_id,
      kind: :last_active_reported,
      source: :extension,
      observed_at: now,
      active_at: at,
      job_id: job.id,
      now: now
    })
  end

  def last_viewed(_scope, _job, _at, _now), do: :ok

  @doc "A message landed: `replied`, with its delay, when it answers one of ours."
  @spec message(Scope.t(), map(), DateTime.t()) :: :ok
  def message(%Scope{} = scope, %{direction: :in, is_internal: false} = m, %DateTime{} = now)
      when is_binary(m.from_contact_id) do
    case parent(m) do
      %{direction: :out, is_internal: false} = parent ->
        delay = DateTime.diff(m.sent_at, parent.sent_at, :second)

        if delay >= 0 do
          observe(scope, %{
            contact_id: m.from_contact_id,
            kind: :replied,
            source: source(m.captured_via),
            observed_at: now,
            active_at: m.sent_at,
            message_id: m.id,
            reply_delay_s: delay,
            now: now
          })
        else
          :ok
        end

      _not_ours ->
        :ok
    end
  end

  def message(_scope, _message, _now), do: :ok

  defp parent(%{parent_message_id: id} = m) when is_binary(id),
    do: Conversations.message(m.organisation_id, id)

  defp parent(%{captured_via: :extension} = m), do: Store.previous_message(m)
  defp parent(_m), do: nil

  defp source(:manual), do: :manual
  defp source(:extension), do: :extension
  defp source(_mail), do: :email

  defp observe(scope, attrs) do
    case Behaviour.observe(scope, attrs) do
      {:ok, _written_or_exists} -> :ok
      {:error, _refused} -> :ok
    end
  end

  @doc """
  Noon of `day` in `zone` (the posting day's stand-in for a time), or
  `nil` without a day.

      iex> Core.Behaviour.Sources.noon(~D[2026-11-10], "Asia/Karachi")
      ~U[2026-11-10 07:00:00.000000Z]
  """
  @spec noon(Date.t() | String.t() | nil, String.t()) :: DateTime.t() | nil
  def noon(nil, _zone), do: nil

  def noon(day, zone) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> noon(date, zone)
      {:error, _bad} -> nil
    end
  end

  def noon(%Date{} = day, zone) do
    naive = NaiveDateTime.new!(day, ~T[12:00:00.000000])

    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      _gap_or_unknown -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
end
