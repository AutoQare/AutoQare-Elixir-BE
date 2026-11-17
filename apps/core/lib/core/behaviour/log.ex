defmodule Core.Behaviour.Log do
  @moduledoc """
  The routes that write an observation, and the extension's reads (AQ-10
  §6.1, §11.4):

  - **`POST /team/v1/observations`** — *Log an observation*: any kind, a
    time, a note of at most 500 characters (QP10-18), `source: manual`, by
    staff who see the subject.
  - **`POST /ext/v1/observations`** — the extension's presence: Upwork's
    `seen_online` while a linked room is open, LinkedIn's
    `last_active_reported` from the *Active* text on a capture press, on
    the thread's contact; idempotent by `request_id`.
  - **`GET /ext/v1/behaviour`** — the subject of the open job or thread,
    and its summary.
  - **`POST /ext/v1/watches`** — *Watch* from the panel: push and the
    extension, a 2-hour cool-down.
  """

  alias Core.Access
  alias Core.Behaviour
  alias Core.Behaviour.Sheet
  alias Core.Ingest.Extension.{Pool, Read}
  alias Core.Watches
  alias Data.Behaviour, as: Store
  alias Data.Conversations
  alias Data.Scope
  alias Data.Vocabulary

  @kinds Vocabulary.observation_kinds()
  @ext_kinds ~w(seen_online last_active_reported)
  @skew_s 120

  # ── By hand ─────────────────────────────────────────────────────────────────

  @doc """
  `POST /team/v1/observations {company_id | contact_id, kind, observed_at,
  active_at?, note?}`: the observation, `source: manual`. `observed_at` and
  `active_at` (it defaults to `observed_at`) may not be after now — a
  clock up to two minutes ahead is taken as now — and the note is at most
  500 characters.
  """
  @spec manual(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def manual(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, subject} <- Behaviour.subject_of(scope, :observe, params),
         {:ok, kind} <- kind(params["kind"], @kinds),
         {:ok, observed_at} <- instant(params, "observed_at", now, nil),
         {:ok, active_at} <- instant(params, "active_at", now, observed_at),
         {:ok, note} <- note(params["note"]),
         {:ok, observation} <-
           Behaviour.observe(scope, %{
             company_id: if(subject.kind == :company, do: subject.id),
             contact_id: if(subject.kind == :contact, do: subject.id),
             kind: kind,
             source: :manual,
             observed_at: observed_at,
             active_at: active_at,
             note: note,
             now: now
           }) do
      shown(scope, observation)
    end
  end

  defp shown(scope, %{id: id}) do
    observation =
      scope
      |> Scope.organisation_id()
      |> Store.get(id)
      |> Data.Repo.preload([:job, :message, observer_user: :person])

    {:ok, Sheet.observation(scope, observation)}
  end

  defp kind(value, kinds) do
    if is_binary(value) and value in kinds,
      do: {:ok, String.to_existing_atom(value)},
      else: invalid("kind", "is one of #{Enum.join(kinds, ", ")}")
  end

  defp instant(params, key, now, default) do
    case params[key] do
      nil when is_nil(default) ->
        {:error, {:missing, [String.to_existing_atom(key)]}}

      nil ->
        {:ok, default}

      value when is_binary(value) ->
        with {:ok, at, _offset} <- DateTime.from_iso8601(value),
             :ok <- not_ahead(at, now, key) do
          {:ok, if(DateTime.after?(at, now), do: now, else: at)}
        else
          {:error, {:invalid, _details}} = error -> error
          _bad -> invalid(key, "is not a time")
        end

      _other ->
        invalid(key, "is not a time")
    end
  end

  defp not_ahead(at, now, key) do
    if DateTime.diff(at, now, :second) > @skew_s,
      do: invalid(key, "can't be in the future"),
      else: :ok
  end

  defp note(nil), do: {:ok, nil}

  defp note(text) when is_binary(text) do
    case Utils.presence(String.trim(text)) do
      nil -> {:ok, nil}
      note when byte_size(note) <= 500 -> {:ok, note}
      note -> if String.length(note) > 500, do: too_long(), else: {:ok, note}
    end
  end

  defp note(_other), do: invalid("note", "is text")

  defp too_long, do: invalid("note", "is at most 500 characters")

  # ── The extension ───────────────────────────────────────────────────────────

  @doc """
  `POST /ext/v1/observations {team_id, kind, thread: {platform,
  external_thread_id}, active_text?, request_id}`: `{:ok, {:created,
  id}}`, or `{:ok, {:replayed, id}}` for a `request_id` already written.
  `last_active_reported` reads `active_text` ("Active now", "Active 2h
  ago", "Last seen 3 hours ago") with P5's `Read.ago` (422 when
  unreadable); the subject is the conversation's contact (404 when the
  team has no such conversation, or it has no contact).
  """
  @spec extension(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), binary()}} | {:error, term()}
  def extension(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, request_id} <- request_id(params["request_id"]) do
      case Store.by_request(Scope.organisation_id(scope), request_id) do
        nil -> observe_presence(scope, request_id, params, now)
        observation -> {:ok, {:replayed, observation.id}}
      end
    end
  end

  defp observe_presence(scope, request_id, params, now) do
    with {:ok, kind} <- kind(params["kind"], @ext_kinds),
         {:ok, team} <- Core.Jobs.team(scope, params),
         {:ok, active_at} <- active_at(kind, params["active_text"], now),
         {:ok, contact_id} <- thread_contact(scope, team, params["thread"]),
         {:ok, subject} <- Behaviour.subject(scope, :observe, :contact, contact_id) do
      result =
        Behaviour.observe(scope, %{
          contact_id: subject.id,
          kind: kind,
          source: :extension,
          observed_at: now,
          active_at: active_at,
          request_id: request_id,
          now: now
        })

      case result do
        {:ok, :exists} -> replayed(scope, request_id)
        {:ok, observation} -> {:ok, {:created, observation.id}}
        error -> error
      end
    end
  end

  defp replayed(scope, request_id) do
    case Store.by_request(Scope.organisation_id(scope), request_id) do
      nil -> {:error, :not_found}
      observation -> {:ok, {:replayed, observation.id}}
    end
  end

  defp active_at(:seen_online, _text, now), do: {:ok, now}

  defp active_at(:last_active_reported, text, now) when is_binary(text) do
    case read_active(text, now) do
      nil -> invalid("active_text", "is not a time we can read")
      at -> {:ok, at}
    end
  end

  defp active_at(:last_active_reported, _none, _now),
    do: {:error, {:missing, [:active_text]}}

  @doc """
  The moment an *Active* text names, counted back from `now`: "Active
  now", "Active 2h ago", "Active 15m ago", "Last seen 3 hours ago" —
  short units spelled out for P5's `Read.ago`; `nil` when unreadable.

      iex> Core.Behaviour.Log.read_active("Active 2h ago", ~U[2026-11-14 10:00:00Z])
      ~U[2026-11-14 08:00:00Z]
      iex> Core.Behaviour.Log.read_active("Active now", ~U[2026-11-14 10:00:00Z])
      ~U[2026-11-14 10:00:00Z]
      iex> Core.Behaviour.Log.read_active("Busy", ~U[2026-11-14 10:00:00Z])
      nil
  """
  @spec read_active(String.t(), DateTime.t()) :: DateTime.t() | nil
  def read_active(text, now) do
    if text =~ ~r/\b(active|online)\s+now\b|^\s*now\s*$/i do
      now
    else
      spelled =
        Enum.reduce(
          [
            {~r/\b(\d+)\s*(?:h|hr|hrs)\b/i, "\\1 hours"},
            {~r/\b(\d+)\s*(?:m|mins?)\b/i, "\\1 minutes"},
            {~r/\b(\d+)\s*d\b/i, "\\1 days"},
            {~r/\b(\d+)\s*w\b/i, "\\1 weeks"},
            {~r/\b(\d+)\s*mo\b/i, "\\1 months"},
            {~r/\b(\d+)\s*y\b/i, "\\1 years"}
          ],
          text,
          fn {regex, with}, acc -> Regex.replace(regex, acc, with) end
        )

      case Read.ago(spelled, now) do
        {at, _slack} -> at
        nil -> nil
      end
    end
  end

  defp thread_contact(scope, team, %{} = thread) do
    with {:ok, platform} <- platform(thread["platform"]),
         id when is_binary(id) and id != "" <- thread["external_thread_id"],
         %{} = c <- Conversations.by_thread(team.id, platform, id),
         :ok <- Access.why_not(scope, :read, {:conversation, Core.Conversations.subject(c)}),
         contact_id when is_binary(contact_id) <- Store.conversation_contact(c.id) do
      {:ok, contact_id}
    else
      {:error, {:invalid, _}} = error -> error
      _none -> {:error, :not_found}
    end
  end

  defp thread_contact(_scope, _team, nil), do: {:error, {:missing, [:thread]}}

  defp thread_contact(_scope, _team, _other),
    do: invalid("thread", "is {platform, external_thread_id}")

  defp platform(value) when value in ["linkedin", "upwork"],
    do: {:ok, String.to_existing_atom(value)}

  defp platform(_value), do: invalid("thread.platform", "is linkedin or upwork")

  defp request_id(id) do
    case is_binary(id) && Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      false -> {:error, {:missing, [:request_id]}}
      :error -> invalid("request_id", "is not a UUID")
    end
  end

  @doc """
  `GET /ext/v1/behaviour?team_id&url=` (a job page) or `?team_id&platform&
  external_thread_id` (a thread): `%{subject, behaviour}` — the team's pool
  job with that key → its company; the team's conversation with that thread
  → its contact. Both `nil` when there is none yet, or the caller may not
  see it.
  """
  @spec subject(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def subject(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, team} <- Core.Jobs.team(scope, params),
         {:ok, found} <- found(scope, team, params) do
      case found && Behaviour.subject(scope, :read, elem(found, 0), elem(found, 1)) do
        {:ok, subject} ->
          {:ok,
           %{subject: Sheet.subject(subject), behaviour: Behaviour.summary(scope, subject, now)}}

        _none ->
          {:ok, %{subject: nil, behaviour: nil}}
      end
    end
  end

  defp found(scope, team, %{"url" => url}) when is_binary(url) and url != "" do
    with {:ok, link} <- Pool.link(url) do
      case Pool.job(scope, team, link) do
        {:job, %{company_id: id}} when is_binary(id) -> {:ok, {:company, id}}
        _none -> {:ok, nil}
      end
    end
  end

  defp found(scope, team, %{"platform" => _platform} = params) do
    case thread_contact(scope, team, Map.take(params, ["platform", "external_thread_id"])) do
      {:ok, contact_id} -> {:ok, {:contact, contact_id}}
      {:error, {:invalid, _details}} = error -> error
      {:error, _none} -> {:ok, nil}
    end
  end

  defp found(_scope, _team, _params),
    do: invalid("url", "give a job's url, or a thread's platform and external_thread_id")

  @doc """
  `POST /ext/v1/watches {team_id, company_id | contact_id, trigger}`: the
  console's make, with push and the extension and a 2-hour cool-down.
  """
  @spec watch(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), map()}} | {:error, term()}
  def watch(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, _team} <- Core.Jobs.team(scope, params) do
      body =
        params
        |> Map.take(["company_id", "contact_id", "trigger"])
        |> Map.merge(%{"channels" => ["push", "extension"], "cooldown_minutes" => 120})

      Watches.create(scope, body, now)
    end
  end

  defp invalid(field, words), do: {:error, {:invalid, %{field => [words]}}}
end
