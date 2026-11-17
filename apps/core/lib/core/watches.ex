defmodule Core.Watches do
  @moduledoc """
  Watches (AQ-10 P10.2, §8, §11.4): *tell me when this company posts a
  job, when this person comes online or replies*. **A watch is its
  owner's own** (PLAN §3): made, changed, paused and removed only by them;
  another person's is not found. Anyone who sees a subject's behaviour may
  watch it (`Core.Access`, `{:behaviour, _}` `:watch`).

  - **Made** from a subject: a trigger it takes (`Core.Watches.Rule`; a
    company `posts_job` · `any_activity`, a contact `comes_online` ·
    `replies` · `any_activity`, anything else 422), channels ⊆ `push ·
    email · extension` (the bell always), a cool-down of 30, 120 or 1440
    minutes, an expiry of none, a week or a month. A second make for the
    same subject and trigger updates the first.
  - **Matched** by `match/1` in the observation's own transaction: every
    watch on the subject whose trigger takes the kind, not paused, not
    expired and past its cool-down ensures one `behaviour.watch_fired` for
    its watcher alone (dedupe `watch:<id>:<observation id>`), on the
    watch's channels, passing quiet hours for *comes online* only, and
    sets `last_fired_at`. The words are `Core.Watches.Words`'.
  - **P10b (AQ-10B §5.7 B1, G8):** a watch doesn't fire for its own
    watcher's hand-logged observation (`source: manual`), and a watch
    whose owner can no longer read its subject doesn't fire: it is
    deleted. `ending/2` tells a watcher of a watch *Forget* removed.
  """

  alias Core.Access
  alias Core.Access.Grants
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Core.Watches.{Rule, Words}
  alias Data.Behaviour.{Observation, Watch}
  alias Data.Repo
  alias Data.Scope
  alias Data.Watches, as: Store

  @channels ~w(push email extension)
  @cooldowns Data.Vocabulary.watch_cooldowns()
  @defaults %{"channels" => ["push", "extension"], "cooldown_minutes" => 120, "expires_in" => nil}

  # ── The person's own ────────────────────────────────────────────────────────

  @doc "`GET /watches`: the caller's own, `{items}`, the expired last."
  @spec list(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, user_id} <- me(scope) do
      {live, expired} = user_id |> Store.mine() |> Enum.split_with(&(not Rule.expired?(&1, now)))
      {:ok, %{items: Enum.map(live ++ expired, &view(&1, now))}}
    end
  end

  @doc "The caller's watches on one subject (the summary's `mine`)."
  @spec mine_on(Scope.t(), Data.Behaviour.subject(), DateTime.t()) :: [map()]
  def mine_on(%Scope{} = scope, key, %DateTime{} = now) do
    case Scope.user_id(scope) do
      nil -> []
      user_id -> user_id |> Store.mine_on(key) |> Enum.map(&view(&1, now))
    end
  end

  @doc """
  `POST /watches {company_id | contact_id, trigger, channels?,
  cooldown_minutes?, expires_in?}`: `{:ok, {:created, watch}}` — what the
  body leaves out is push and the extension, 2 h, no expiry (QP10-9) — or
  `{:ok, {:updated, watch}}` for the caller's watch on the same subject
  and trigger, with the settings sent.
  """
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), map()}} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, user_id} <- me(scope),
         {:ok, subject} <- Core.Behaviour.subject_of(scope, :watch, params),
         {:ok, trigger} <- trigger(subject.kind, params["trigger"]) do
      case Store.find(user_id, {subject.kind, subject.id}, trigger) do
        nil -> make(scope, user_id, {subject, trigger}, params, now)
        watch -> renew(watch, params, now)
      end
    end
  end

  defp make(scope, user_id, {subject, trigger}, params, now) do
    with {:ok, settings} <- settings(params, now, @defaults) do
      %{
        organisation_id: Scope.organisation_id(scope),
        user_id: user_id,
        company_id: if(subject.kind == :company, do: subject.id),
        contact_id: if(subject.kind == :contact, do: subject.id),
        trigger: trigger
      }
      |> Map.merge(settings)
      |> Store.create()
      |> answer(:created, now)
    end
  end

  defp renew(watch, params, now) do
    with {:ok, settings} <- settings(params, now, %{}),
         do: watch |> Store.update(settings) |> answer(:updated, now)
  end

  @doc "`PATCH /watches/:id`: any of `{channels, cooldown_minutes, expires_in, paused}`; another person's is not found."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, watch} <- fetch(scope, id),
         {:ok, settings} <- settings(params, now, %{}),
         {:ok, paused} <- paused(params, watch, now) do
      watch
      |> Store.update(Map.merge(settings, paused))
      |> answer(:updated, now)
      |> case do
        {:ok, {:updated, view}} -> {:ok, view}
        error -> error
      end
    end
  end

  @doc "`DELETE /watches/:id`: the caller's own; another person's is not found."
  @spec delete(Scope.t(), term()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id) do
    with {:ok, watch} <- fetch(scope, id),
         {:ok, _gone} <- Store.delete(watch),
         do: :ok
  end

  defp fetch(scope, id) do
    with {:ok, user_id} <- me(scope),
         %Watch{} = watch <- Store.get_own(user_id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :update, {:watch, watch}),
         do: {:ok, watch}
  end

  # Staff only: a customer has no watches, and no route finds one (QP10-14).
  defp me(scope) do
    case {Scope.staff?(scope) and not Scope.customer?(scope), Scope.user_id(scope)} do
      {true, id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp answer({:ok, watch}, how, now), do: {:ok, {how, view(watch, now)}}
  defp answer({:error, _changeset} = error, _how, _now), do: error

  # ── The body ────────────────────────────────────────────────────────────────

  defp trigger(kind, value) do
    takes = Rule.triggers(kind)
    names = Enum.map(takes, &Atom.to_string/1)

    if is_binary(value) and value in names,
      do: {:ok, String.to_existing_atom(value)},
      else: invalid("trigger", "is one a #{kind} takes: #{Enum.join(names, ", ")}")
  end

  # What was sent of the settings, else the defaults, checked.
  defp settings(params, now, defaults) do
    with {:ok, channels} <- pick(params, defaults, "channels", &channels/1),
         {:ok, cooldown} <- pick(params, defaults, "cooldown_minutes", &cooldown/1),
         {:ok, expiry} <- expiry(params, defaults, now) do
      {:ok,
       %{channels: channels, cooldown_minutes: cooldown, expires_at: expiry}
       |> Map.reject(fn {_k, v} -> v == :keep end)}
    end
  end

  defp pick(params, defaults, key, check) do
    case Map.fetch(params, key) do
      {:ok, value} -> check.(value)
      :error -> if Map.has_key?(defaults, key), do: check.(defaults[key]), else: {:ok, :keep}
    end
  end

  defp channels(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @channels)),
      do: {:ok, list |> Enum.uniq() |> Enum.map(&String.to_existing_atom/1)},
      else: invalid("channels", "are some of push, email, extension")
  end

  defp channels(_other), do: invalid("channels", "are some of push, email, extension")

  defp cooldown(n) when n in @cooldowns, do: {:ok, n}
  defp cooldown(_n), do: invalid("cooldown_minutes", "is 30, 120 or 1440")

  defp expiry(params, defaults, now) do
    value =
      case Map.fetch(params, "expires_in") do
        {:ok, value} -> {:sent, value}
        :error -> if Map.has_key?(defaults, "expires_in"), do: {:sent, defaults["expires_in"]}
      end

    case value do
      nil ->
        {:ok, :keep}

      {:sent, choice} ->
        case Rule.expires_at(choice, now) do
          {:ok, at} -> {:ok, at}
          :error -> invalid("expires_in", "is none, week or month")
        end
    end
  end

  defp paused(%{"paused" => true}, %Watch{paused_at: nil}, now), do: {:ok, %{paused_at: now}}
  defp paused(%{"paused" => true}, _watch, _now), do: {:ok, %{}}
  defp paused(%{"paused" => false}, _watch, _now), do: {:ok, %{paused_at: nil}}
  defp paused(%{"paused" => nil}, _watch, _now), do: {:ok, %{}}
  defp paused(%{"paused" => _other}, _watch, _now), do: invalid("paused", "is true or false")
  defp paused(_params, _watch, _now), do: {:ok, %{}}

  defp invalid(field, words), do: {:error, {:invalid, %{field => [words]}}}

  # ── The shape ───────────────────────────────────────────────────────────────

  @doc """
  A **watch** (§11.4): `{id, subject: {kind, id, name}, trigger, channels,
  cooldown_minutes, expires_at?, last_fired_at?, paused_at?, is_expired,
  inserted_at}`.
  """
  @spec view(Watch.t(), DateTime.t()) :: map()
  def view(%Watch{} = w, %DateTime{} = now) do
    subject =
      if w.company_id,
        do: %{kind: :company, id: w.company_id, name: w.company && w.company.name},
        else: %{kind: :contact, id: w.contact_id, name: w.contact && w.contact.name}

    %{
      id: w.id,
      subject: subject,
      trigger: w.trigger,
      channels: w.channels,
      cooldown_minutes: w.cooldown_minutes,
      expires_at: w.expires_at,
      last_fired_at: w.last_fired_at,
      paused_at: w.paused_at,
      is_expired: Rule.expired?(w, now),
      inserted_at: w.inserted_at
    }
  end

  # ── The matcher ─────────────────────────────────────────────────────────────

  @doc """
  The watches an observation fires, inside its transaction (§8): each due
  watch on its subject ensures one `behaviour.watch_fired` for its
  watcher and is marked fired. *Now* is the observation's `inserted_at`
  (the writer's clock). Answers the socket events the new rows make.
  """
  @spec match(Observation.t()) :: list()
  def match(%Observation{} = o) do
    key = Core.Behaviour.key(o)
    now = o.inserted_at

    due =
      key
      |> Store.on_subject_for_update()
      |> Enum.filter(&Rule.due?(&1, o.kind, now))
      |> Enum.reject(&own_hand?(&1, o))
      |> Enum.filter(&still_readable?(&1, key))

    case due do
      [] -> []
      due -> fire(o, due, key, now)
    end
  end

  # AQ-10B G8: the watcher logged it by hand themselves.
  defp own_hand?(watch, o), do: o.source == :manual and o.observer_user_id == watch.user_id

  # AQ-10B G8: the owner lost access (left the team, suspended): the watch goes.
  defp still_readable?(watch, {kind, id}) do
    readable? =
      case Data.Accounts.get_user(watch.user_id) do
        nil ->
          false

        user ->
          scope = Grants.scope_for(user)
          match?({:ok, _subject}, Core.Behaviour.subject_of(scope, :watch, %{"#{kind}_id" => id}))
      end

    if not readable?, do: {:ok, _gone} = Store.delete(watch)
    readable?
  end

  @doc """
  `behaviour.watch_ending` (AQ-10B §5.7 B2) to the watchers of `watches`
  *Forget* removed (`reason: :forgotten`) or the scan finds expiring
  tomorrow (`:expiring`). Answers the socket events.
  """
  @spec ending([Watch.t()], :forgotten | :expiring, DateTime.t()) :: list()
  def ending(watches, reason, %DateTime{} = now) do
    for watch <- watches do
      scope = Scope.system(%{id: watch.organisation_id})
      name = subject_name(scope, watch)

      {title, dedupe} =
        case reason do
          :forgotten ->
            {"Your watch on #{name} was removed: they were forgotten",
             "watch:#{watch.id}:forgotten"}

          :expiring ->
            {"Your watch on #{name} ends tomorrow",
             "watch:#{watch.id}:ending:#{DateTime.to_iso8601(watch.expires_at)}"}
        end

      {:ok, row} =
        Notifications.ensure(
          scope,
          %{
            organisation_id: watch.organisation_id,
            user_id: watch.user_id,
            notification_kind_key: "behaviour.watch_ending",
            title: title,
            body: if(reason == :expiring, do: "Renew it from Behaviour if you still need it."),
            link_path: "/behaviour",
            dedupe_key: dedupe
          },
          now
        )

      if row.is_new,
        do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
        else: []
    end
  end

  defp subject_name(scope, %Watch{company_id: id}) when is_binary(id),
    do: (Core.Behaviour.load(scope, :company, id) || %{name: "a company"}).name

  defp subject_name(scope, %Watch{contact_id: id}) when is_binary(id),
    do: (Core.Behaviour.load(scope, :contact, id) || %{name: "someone"}).name

  defp fire(o, due, {kind, id}, now) do
    scope = Scope.system(%{id: o.organisation_id})
    ctx = context(scope, o, kind, id)

    for watch <- due do
      {:ok, row} =
        Notifications.ensure(
          scope,
          %{
            organisation_id: o.organisation_id,
            user_id: watch.user_id,
            notification_kind_key: "behaviour.watch_fired",
            actor_user_id: o.observer_user_id,
            lead_id: ctx.lead && ctx.lead.id,
            title: Words.title(ctx),
            body: o.note,
            link_path: Words.link(ctx),
            dedupe_key: "watch:#{watch.id}:#{o.id}",
            only_channels: Enum.map(watch.channels, &Atom.to_string/1),
            passes_quiet_hours: Rule.passes_quiet_hours?(watch.trigger)
          },
          now
        )

      {:ok, _fired} = Store.fired(watch, now)

      if row.is_new,
        do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
        else: []
    end
  end

  # What the words need: the subject, the job, the observer, a reply's lead.
  defp context(scope, o, kind, id) do
    o = Repo.preload(o, [:job, message: :conversation, observer_user: :person])
    subject = Core.Behaviour.load(scope, kind, id)

    %{
      kind: o.kind,
      source: o.source,
      subject: %{kind: kind, id: id, name: subject.name, company: subject.company},
      job: o.job && %{title: o.job.title},
      observer: Person.first_name(o.observer_user),
      ago: max(DateTime.diff(o.observed_at, o.active_at, :second), 0),
      lead: reply_lead(o.message)
    }
  end

  defp reply_lead(nil), do: nil

  defp reply_lead(message) do
    case Data.Conversations.lead_ids(message.conversation_id) do
      [lead_id | _rest] ->
        lead = Data.Leads.get(message.organisation_id, lead_id)

        lead &&
          %{
            id: lead.id,
            title: lead.job.title,
            company: lead.job.company && lead.job.company.name
          }

      [] ->
        nil
    end
  end
end
