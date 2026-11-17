defmodule Core.Leads.Notices do
  @moduledoc """
  Who is told what about a lead (AQ-04A §10.1, QP4a-13), **inside the
  verb's transaction**, each row ensured by its dedupe key
  (`Core.Notifications.ensure/2`, which plans the row's
  deliveries in the same transaction, AQ-08 §7.1) and its words **frozen in the recipient's
  terms**, as P2's are.

  | Kind | Who | Dedupe key |
  |---|---|---|
  | `leads.assigned` | the new owner, when someone else made them owner | `lead:<id>:owner:<event id>` |
  | `leads.moved` | the owner, when someone else (staff or the customer) moved their lead's state, stage or outcome | `lead:<id>:moved:<event id>` |
  | `leads.applied_again` | the **team leads** of the lead's team | `lead:<id>:again:<event id>` |
  | `leads.customer_update` | the customer, for a customer-visible move that isn't a milestone: applied, a stage, an outcome, reopened | `lead:<id>:customer:<event id>` |
  | `leads.customer_milestone` | the customer, when their lead reaches an interview stage, an offer or *Hired* (AQ-08 QP8-4: with push and email); a customer with no login by email alone (AQ-10B QP10b-2) | `lead:<id>:customer:<event id>` |

  **P10b (AQ-10B §5.3, §11.4):**

  | Kind | Who | Dedupe key |
  |---|---|---|
  | `leads.moved` | also the lead's watchers (QP10b-15) | as above |
  | `leads.taken` | the previous owner, when someone else hands the lead on | `lead:<id>:taken:<event id>` |
  | `leads.milestone_team` | the team leads, at an interview, an offer, *Hired* | `lead:<id>:milestone:<event id>` |
  | `leads.customer_applied` | the profile's owners, when the customer said *I applied* in the portal | `lead:<id>:customer_applied:<event id>` |
  | `leads.job_closed` | the owners of a closed job's open leads | `lead:<id>:job_closed:<closed at>` |
  | `leads.job_merged` | the owners of the merged job's open leads | `lead:<id>:job_merged:<into job>` |

  A milestone is a stage whose kind is `interview`, `ai_interview`,
  `final` or `offer`, or *Hired* — not a custom stage merely anchored to
  one (AQ-10B §11.4, G8).

  Staff read the actor's first name (the customer's acts by the customer's
  name); the customer reads the first name only when the lead's team has
  `customer_sees_staff_names` on, else "The team" — and then the row carries
  no actor at all. Nobody is told of their own act. Each row's deliveries
  are planned by the seam (AQ-08 §7.1).

  Each function answers the socket events its new rows make
  (`notification_created`), for `Core.Tasks.Write.commit/1` to send after
  commit.
  """

  alias Core.Leads.Words
  alias Core.Notifications
  alias Core.Notifications.CustomerMail
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Notifications.LeadWatchers
  alias Data.Scope
  alias Data.Teams

  @doc "`leads.assigned` to the new owner."
  @spec assigned(Scope.t(), map(), map()) :: list()
  def assigned(scope, lead, event) do
    actor = actor(scope)

    tell(scope, lead.owner_user_id, "leads.assigned", lead,
      title: "#{name(actor, lead)} handed you #{Words.job(lead.job)}",
      body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
      actor: actor,
      dedupe: "lead:#{lead.id}:owner:#{event.id}"
    )
  end

  @doc """
  `leads.taken` (AQ-10B §5.3 L2) to the previous owner when someone else
  handed the lead on: "Fiza handed “Backend Developer · Bamboo Invest” to
  Hira."
  """
  @spec taken(Scope.t(), map(), binary() | nil, map()) :: list()
  def taken(scope, lead, previous_owner_id, event) do
    actor = actor(scope)
    to = lead.owner_user_id && Accounts.get_user(lead.owner_user_id)

    tell(scope, previous_owner_id, "leads.taken", lead,
      title:
        "#{name(actor, lead)} handed #{Words.job(lead.job)} to #{Person.first_name(to) || "someone else"}.",
      body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
      actor: actor,
      dedupe: "lead:#{lead.id}:taken:#{event.id}"
    )
  end

  @doc """
  `leads.moved` to the owner and the lead's watchers (AQ-10B QP10b-15):
  "Fiza moved “Backend Developer · Bamboo Invest” to Technical interview 1."
  """
  @spec moved(Scope.t(), map(), map(), String.t()) :: list()
  def moved(scope, lead, event, to) do
    actor = actor(scope)

    for user_id <- Enum.uniq([lead.owner_user_id | LeadWatchers.watchers(lead.id)]) do
      tell(scope, user_id, "leads.moved", lead,
        title: "#{name(actor, lead)} moved #{Words.job(lead.job)} to #{to}.",
        body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
        actor: actor,
        dedupe: "lead:#{lead.id}:moved:#{event.id}"
      )
    end
  end

  @doc """
  `leads.customer_applied` (AQ-10B §5.3 L8) to the profile's owners when
  the customer said *I applied* in the portal: "Tanweer applied to
  “Backend Developer” at Bamboo Invest as “Golang backend”."
  """
  @spec customer_applied(Scope.t(), map(), map()) :: list()
  def customer_applied(scope, lead, event) do
    customer = lead.profile.customer

    for user_id <- Enum.uniq(profile_owners(lead.profile_id)) do
      tell(scope, user_id, "leads.customer_applied", lead,
        title:
          "#{customer.display_name} applied to #{Words.job_at(lead.job)} as " <>
            "#{Words.quoted(lead.profile.title)}",
        actor: actor(scope),
        dedupe: "lead:#{lead.id}:customer_applied:#{event.id}"
      )
    end
  end

  @doc """
  `leads.job_closed` (AQ-10B §5.3 J1) to each open lead's owner when its
  job was closed: "Fiza closed “Backend Developer · Bamboo Invest”: your
  lead for Golang is still open."
  """
  @spec job_closed(Scope.t(), [map()], DateTime.t()) :: list()
  def job_closed(scope, leads, %DateTime{} = at) do
    actor = actor(scope)

    for lead <- leads do
      tell(scope, lead.owner_user_id, "leads.job_closed", lead,
        title:
          "#{name(actor, lead)} closed #{Words.job(lead.job)}: your lead for " <>
            "#{lead.profile.customer.display_name} is still open",
        body: "Finish it, or keep it if the company is still talking to you.",
        actor: actor,
        dedupe: "lead:#{lead.id}:job_closed:#{DateTime.to_iso8601(at)}"
      )
    end
  end

  @doc """
  `leads.job_merged` (AQ-10B §5.3 J2) to each open lead's owner when its
  job was merged into another: "Fiza merged “…” into “…”".
  """
  @spec job_merged(Scope.t(), [map()], map()) :: list()
  def job_merged(scope, leads, into) do
    actor = actor(scope)

    for lead <- leads do
      tell(scope, lead.owner_user_id, "leads.job_merged", lead,
        title: "#{name(actor, lead)} merged a job into #{Words.job(into)}",
        body: "Your lead for #{lead.profile.customer.display_name} moved with it.",
        actor: actor,
        dedupe: "lead:#{lead.id}:job_merged:#{into.id}"
      )
    end
  end

  defp profile_owners(profile_id) do
    import Ecto.Query, only: [from: 2]

    from(m in Data.Customers.ProfileMember, where: m.profile_id == ^profile_id, select: m.user_id)
    |> Data.Repo.all()
  end

  @doc "`leads.applied_again` to the team leads of the lead's team, with the reason."
  @spec applied_again(Scope.t(), map(), map()) :: list()
  def applied_again(scope, lead, event) do
    actor = actor(scope)

    for member <- Teams.list_members(lead.job.team_id), member.role == :lead do
      tell(scope, member.user_id, "leads.applied_again", lead,
        title:
          "#{name(actor, lead)} applied again as #{Words.quoted(lead.profile.title)} " <>
            "on #{Words.job(lead.job)}",
        body: event.note,
        actor: actor,
        dedupe: "lead:#{lead.id}:again:#{event.id}"
      )
    end
  end

  @doc """
  `leads.customer_update` to the customer: `what` is `:applied`, `{:stage,
  stage}` (the stage moved to), `{:outcome, outcome}` or `:reopened`. "The team applied to
  “Backend Developer” at Bamboo Invest as “Golang backend”."

  **A milestone is its own kind** (AQ-08 QP8-4): a move to an interview
  stage (`interview`, `ai_interview`, `final`, or a custom stage anchored to
  one), to an offer, or the outcome *Hired* raises
  `leads.customer_milestone` in the same words, which also pushes and
  emails the customer.
  """
  @spec customer_update(Scope.t(), map(), map(), term()) :: list()
  def customer_update(scope, lead, event, what) do
    customer = lead.profile.customer
    milestone? = milestone?(lead, what)
    team = if milestone?, do: milestone_team(scope, lead, event, what), else: []

    told =
      case customer.user_id do
        nil ->
          if milestone?, do: mail_milestone(lead, event, what), else: []

        user_id ->
          tell_customer(scope, lead, event, what, user_id, milestone?)
      end

    [team, told]
  end

  # AQ-10B QP10b-2: a milestone mailed to a customer with no login.
  defp mail_milestone(lead, event, what) do
    customer = lead.profile.customer
    names? = Teams.get_settings(lead.job.team_id).customer_sees_staff_names
    {who, _actor} = for_customer(nil, names?)

    _written =
      CustomerMail.write(
        customer,
        %{
          kind: "leads.customer_milestone",
          subject: customer_words(who, lead, what),
          text: "Your team will be in touch with the details.",
          dedupe: "lead:#{lead.id}:customer:#{event.id}"
        },
        Core.Clock.now()
      )

    []
  end

  # AQ-10B §5.3 L7: the team leads, for oversight.
  defp milestone_team(scope, lead, event, what) do
    actor = actor(scope)
    customer = lead.profile.customer.display_name

    words =
      case what do
        {:outcome, :hired} -> "#{customer} was hired on #{Words.job(lead.job)}"
        {:stage, %{name: stage}} -> "#{customer} reached #{stage} on #{Words.job(lead.job)}"
      end

    for member <- Teams.list_members(lead.job.team_id), member.role == :lead do
      tell(scope, member.user_id, "leads.milestone_team", lead,
        title: words,
        body: lead.profile.title,
        actor: actor,
        dedupe: "lead:#{lead.id}:milestone:#{event.id}"
      )
    end
  end

  defp tell_customer(scope, lead, event, what, user_id, milestone?) do
    names? = Teams.get_settings(lead.job.team_id).customer_sees_staff_names
    {who, actor} = scope |> actor() |> for_customer(names?)
    kind = if milestone?, do: "leads.customer_milestone", else: "leads.customer_update"

    tell(scope, user_id, kind, lead,
      title: customer_words(who, lead, what),
      actor: actor,
      link: "/applications/#{lead.id}",
      dedupe: "lead:#{lead.id}:customer:#{event.id}"
    )
  end

  @milestone_stages [:interview, :ai_interview, :final, :offer]

  @doc """
  Whether a customer-visible move is a milestone (AQ-08 §6; AQ-10B §11.4):
  a stage whose kind is an interview (`interview`, `ai_interview`,
  `final`) or an offer, or *Hired*. A custom stage is never one, even
  anchored to an interview (G8).
  """
  @spec milestone?(map(), term()) :: boolean()
  def milestone?(_lead, {:outcome, outcome}), do: outcome == :hired
  def milestone?(_lead, {:stage, %{kind: :custom}}), do: false
  def milestone?(_lead, {:stage, %{kind: kind}}), do: kind in @milestone_stages
  def milestone?(_lead, _what), do: false

  defp customer_words(who, lead, :applied),
    do: "#{who} applied to #{Words.job_at(lead.job)} as #{Words.quoted(lead.profile.title)}."

  defp customer_words(who, lead, {:stage, %{name: stage}}),
    do: "#{who} moved your application to #{Words.job_at(lead.job)} to #{stage}."

  defp customer_words(who, lead, {:outcome, outcome}),
    do: "#{who} marked your application to #{Words.job_at(lead.job)} #{Words.outcome(outcome)}."

  defp customer_words(who, lead, :reopened),
    do: "#{who} reopened your application to #{Words.job_at(lead.job)}."

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # The actor as the customer is told: their first name, or "The team" and
  # no actor on the row.
  defp for_customer(nil, _names?), do: {"The team", nil}
  defp for_customer(actor, true), do: {Person.first_name(actor) || "The team", actor}
  defp for_customer(_actor, false), do: {"The team", nil}

  defp actor(scope) do
    case Scope.user_id(scope) do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end

  defp name(nil, _lead), do: "The team"

  # The team knows the customer by the customer's name, not the account's.
  defp name(%{id: id}, %{profile: %{customer: %{user_id: id, display_name: customer_name}}}),
    do: customer_name

  defp name(actor, _lead), do: Person.first_name(actor) || "Someone"

  defp tell(scope, user_id, kind, lead, opts) do
    if is_nil(user_id) or user_id == Scope.user_id(scope) do
      []
    else
      actor = opts[:actor]

      {:ok, row} =
        Notifications.ensure(scope, %{
          organisation_id: lead.organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          actor_user_id: actor && actor.id,
          lead_id: lead.id,
          title: opts[:title],
          body: opts[:body],
          link_path: opts[:link] || "/leads/#{lead.id}",
          dedupe_key: opts[:dedupe]
        })

      if row.is_new,
        do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
        else: []
    end
  end
end
