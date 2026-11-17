defmodule ApiShared.BehaviourJSON do
  @moduledoc """
  Behaviour's shapes (AQ-10 §11.4, pinned before the build so the three
  repos build to one contract): the **behaviour** summary, the **watch**,
  the **observation**, the **heat** map, the subject's page, the
  Behaviour list, and the extension's answers. `Core.Behaviour` and
  `Core.Watches` fill them; this module lists every field by name, so
  nothing reaches the wire unasked. Keys are snake_case, no map is keyed
  by data, optional members are `null`.
  """

  alias ApiShared.JobsJSON

  @doc """
  **behaviour**: `{sentence, enough, seen, last_seen: {at, words}?,
  time_zone, time_zone_source?, watchers: [{id, name}], mine: [watch]}`;
  `nil` passes through (a subject the caller may not read).
  """
  def summary(nil), do: nil

  def summary(b) do
    %{
      sentence: b.sentence,
      enough: b.enough,
      seen: b.seen,
      last_seen: last_seen(b.last_seen),
      time_zone: b.time_zone,
      time_zone_source: b.time_zone_source,
      watchers: Enum.map(b.watchers, &Map.take(&1, [:id, :name])),
      mine: Enum.map(b.mine, &watch/1)
    }
  end

  defp last_seen(nil), do: nil
  defp last_seen(l), do: Map.take(l, [:at, :words])

  @doc """
  **watch**: `{id, subject: {kind, id, name}, trigger, channels,
  cooldown_minutes, expires_at?, last_fired_at?, paused_at?, is_expired,
  inserted_at}`.
  """
  def watch(w) do
    %{
      id: w.id,
      subject: Map.take(w.subject, [:kind, :id, :name]),
      trigger: w.trigger,
      channels: w.channels,
      cooldown_minutes: w.cooldown_minutes,
      expires_at: w.expires_at,
      last_fired_at: w.last_fired_at,
      paused_at: w.paused_at,
      is_expired: w.is_expired,
      inserted_at: w.inserted_at
    }
  end

  @doc "`GET /watches`: `{items: [watch]}`."
  def watches(%{items: items}), do: %{items: Enum.map(items, &watch/1)}

  @doc """
  **observation**: `{id, kind, source, observed_at, active_at, observer:
  {id, name}?, job: {id, title}?, conversation_id?, reply_delay_s?, note?}`.
  """
  def observation(o) do
    %{
      id: o.id,
      kind: o.kind,
      source: o.source,
      observed_at: o.observed_at,
      active_at: o.active_at,
      observer: o.observer && Map.take(o.observer, [:id, :name]),
      job: o.job && Map.take(o.job, [:id, :title]),
      conversation_id: o.conversation_id,
      reply_delay_s: o.reply_delay_s,
      note: o.note
    }
  end

  @doc "A page of observations: `{items, next_cursor}`."
  def observations(%{items: items, next_cursor: next}),
    do: %{items: Enum.map(items, &observation/1), next_cursor: next}

  @doc "A subject: `{kind, id, name, company: {id, name}?}`."
  def subject(nil), do: nil

  def subject(s) do
    %{
      kind: s.kind,
      id: s.id,
      name: s.name,
      company: s.company && Map.take(s.company, [:id, :name])
    }
  end

  @doc "**heat**: `{ours: {zone, cells}, theirs: {zone, cells}?}`, cells 7 × 24."
  def heat(h), do: %{ours: zone_cells(h.ours), theirs: zone_cells(h.theirs)}

  defp zone_cells(nil), do: nil
  defp zone_cells(z), do: %{zone: z.zone, cells: z.cells}

  @doc """
  `GET /behaviour/:kind/:id`: `{subject, behaviour, heat, reply_delay:
  {median_s, words}?, cadence: {per_week, weekday?, hour?, words}?,
  observations: {items, next_cursor}, jobs: [P3's job row]}`.
  """
  def page(p) do
    %{
      subject: subject(p.subject),
      behaviour: summary(p.behaviour),
      heat: heat(p.heat),
      reply_delay: p.reply_delay && Map.take(p.reply_delay, [:median_s, :words]),
      cadence: p.cadence && Map.take(p.cadence, [:per_week, :weekday, :hour, :words]),
      observations: observations(p.observations),
      jobs: Enum.map(p.jobs, &JobsJSON.row/1)
    }
  end

  @doc """
  `GET /behaviour`: `{items: [{subject, last_seen?, sentence, watchers_count,
  watching, leads_open}], next_cursor}`.
  """
  def list(%{items: items, next_cursor: next}) do
    %{
      items:
        Enum.map(items, fn row ->
          %{
            subject: subject(row.subject),
            last_seen: last_seen(row.last_seen),
            sentence: row.sentence,
            watchers_count: row.watchers_count,
            watching: row.watching,
            leads_open: row.leads_open
          }
        end),
      next_cursor: next
    }
  end

  @doc "`GET /ext/v1/behaviour`: `{subject: {kind, id, name}?, behaviour?}`."
  def ext_subject(%{subject: s, behaviour: b}) do
    %{subject: s && Map.take(s, [:kind, :id, :name]), behaviour: summary(b)}
  end

  @doc "`POST /ext/v1/observations`: `{observation_id}`, with `replayed: true` for a known `request_id`."
  def ext_observed({:created, id}), do: %{observation_id: id}
  def ext_observed({:replayed, id}), do: %{observation_id: id, replayed: true}

  @doc "`POST /companies/:id/forget-people`: `{forgotten}`."
  def forgotten(%{forgotten: n}), do: %{forgotten: n}
end
