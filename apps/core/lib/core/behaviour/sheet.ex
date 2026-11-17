defmodule Core.Behaviour.Sheet do
  @moduledoc """
  Behaviour's read shapes (AQ-10 §11.4), filled here and listed field by
  field in `ApiShared.BehaviourJSON`: the subject ref, the observation,
  and the cursors (a keyset for a subject's timeline, an offset for the
  Behaviour list), opaque to the client.
  """

  alias Core.Access
  alias Data.Behaviour.Observation
  alias Data.Scope

  @doc "A subject as every answer names it: `{kind, id, name, company: {id, name}?}`."
  @spec subject(map()) :: map()
  def subject(s), do: %{kind: s.kind, id: s.id, name: s.name, company: s.company}

  @doc """
  An **observation**: `{id, kind, source, observed_at, active_at, observer:
  {id, name}?, job: {id, title}?, conversation_id?, reply_delay_s?, note?}`
  — `job` only when the caller may see it.
  """
  @spec observation(Scope.t(), Observation.t()) :: map()
  def observation(%Scope{} = scope, %Observation{} = o) do
    %{
      id: o.id,
      kind: o.kind,
      source: o.source,
      observed_at: o.observed_at,
      active_at: o.active_at,
      observer: observer(o.observer_user),
      job: job(scope, o.job),
      conversation_id: o.message && o.message.conversation_id,
      reply_delay_s: o.reply_delay_s,
      note: o.note
    }
  end

  defp observer(%{id: id, person: %{display_name: name}}), do: %{id: id, name: name}
  defp observer(_none), do: nil

  defp job(scope, %{id: id, title: title} = job) do
    if Access.can?(scope, :read, {:job, job}), do: %{id: id, title: title}
  end

  defp job(_scope, _none), do: nil

  # ── Cursors ─────────────────────────────────────────────────────────────────

  @doc "The timeline's cursor after `observation`: its `{active_at, id}`."
  @spec encode_cursor(Observation.t()) :: String.t()
  def encode_cursor(%Observation{active_at: at, id: id}),
    do: Base.url_encode64("#{DateTime.to_iso8601(at)}|#{id}", padding: false)

  @doc "A timeline cursor back to its key; `nil` for none."
  @spec decode_cursor(term()) :: {:ok, {DateTime.t(), binary()} | nil} | {:error, term()}
  def decode_cursor(value) when value in [nil, ""], do: {:ok, nil}

  def decode_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         [at, id] <- String.split(decoded, "|"),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _bad -> bad_cursor()
    end
  end

  def decode_cursor(_value), do: bad_cursor()

  @doc "The list's cursor: how many rows came before."
  @spec encode_offset(non_neg_integer()) :: String.t()
  def encode_offset(n), do: Base.url_encode64("o:#{n}", padding: false)

  @doc "The list's cursor back to its offset; 0 for none."
  @spec decode_offset(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_offset(value) when value in [nil, ""], do: {:ok, 0}

  def decode_offset(value) when is_binary(value) do
    with {:ok, "o:" <> n} <- Base.url_decode64(value, padding: false),
         {n, ""} when n >= 0 <- Integer.parse(n) do
      {:ok, n}
    else
      _bad -> bad_cursor()
    end
  end

  def decode_offset(_value), do: bad_cursor()

  defp bad_cursor, do: {:error, {:invalid, %{"cursor" => ["is not a cursor this API gave"]}}}
end
