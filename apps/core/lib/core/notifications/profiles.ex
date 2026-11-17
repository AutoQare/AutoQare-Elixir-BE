defmodule Core.Notifications.Profiles do
  @moduledoc """
  Who is told when a customer's profile, documents or channels change, or
  who looks after them changes (AQ-10B §5.7, §11.4), through the seam:

  | Kind | Who | Dedupe |
  |---|---|---|
  | `profiles.updated_by_team` | the customer (with a login), when staff changed their CV, a document or a profile | `customer:<id>:by_team:<what>:<at>` |
  | `profiles.updated_by_customer` | the profiles' owners, when the customer changed a document, a channel or a profile | `customer:<id>:by_customer:<what>:<at>` |
  | `profiles.owners_changed` | the new owners and the team leads, when a profile's owners changed; the team's leads when the customer joined or left a team | `profile:<id>:owners:<at>` · `customer:<id>:team:<team>:<at>` |

  Never the actor. The customer reads "Your team"; staff read the
  customer's name.
  """

  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Scope
  alias Data.Teams

  @doc """
  A change to a customer's things by `scope`: `what` is what changed in
  words ("the profile “Golang backend”", "a document: CV"), `profile` the
  profile it belongs to (or `nil` for the customer's channels). Staff
  tell the customer; the customer tells the owners.
  """
  @spec changed(Scope.t(), map(), map() | nil, String.t(), DateTime.t()) :: list()
  def changed(%Scope{} = scope, customer, profile, what, %DateTime{} = now) do
    at = DateTime.to_unix(now, :microsecond)

    if Scope.customer?(scope) do
      owners =
        case profile do
          %{profile_members: members} when is_list(members) -> Enum.map(members, & &1.user_id)
          _all -> owners_of(customer)
        end

      for user_id <- Enum.uniq(owners), user_id != Scope.user_id(scope) do
        tell(customer, user_id, "profiles.updated_by_customer", now,
          title: "#{customer.display_name} changed #{what}",
          actor: Scope.user_id(scope),
          link: "/customers/#{customer.id}",
          dedupe: "customer:#{customer.id}:by_customer:#{hash(what)}:#{at}"
        )
      end
    else
      case customer.user_id do
        nil ->
          []

        user_id ->
          tell(customer, user_id, "profiles.updated_by_team", now,
            title: "Your team updated #{what}",
            link: if(profile, do: "/profiles/#{profile.id}", else: "/channels"),
            dedupe: "customer:#{customer.id}:by_team:#{hash(what)}:#{at}"
          )
      end
    end
  end

  @doc """
  A profile's owners changed (`before` and `after` user ids): the new
  owners ("Fiza made you an owner of Tanweer · Golang backend") and the
  leads of the customer's teams ("Fiza changed who looks after Tanweer ·
  Golang backend"), never the actor.
  """
  @spec owners_changed(Scope.t(), map(), map(), [binary()], [binary()], DateTime.t()) :: list()
  def owners_changed(%Scope{} = scope, customer, profile, before, after_ids, %DateTime{} = now) do
    who = actor_name(scope)
    about = "#{customer.display_name} · #{profile.title}"
    dedupe = "profile:#{profile.id}:owners:#{DateTime.to_unix(now, :microsecond)}"
    new = after_ids -- before
    leads = leads_of(team_ids(customer)) -- new

    told_new =
      for user_id <- new, user_id != Scope.user_id(scope) do
        tell(customer, user_id, "profiles.owners_changed", now,
          title: "#{who} made you an owner of #{about}",
          actor: Scope.user_id(scope),
          link: "/customers/#{customer.id}",
          dedupe: dedupe
        )
      end

    told_leads =
      for user_id <- Enum.uniq(leads), user_id != Scope.user_id(scope), before != after_ids do
        tell(customer, user_id, "profiles.owners_changed", now,
          title: "#{who} changed who looks after #{about}",
          actor: Scope.user_id(scope),
          link: "/customers/#{customer.id}",
          dedupe: dedupe
        )
      end

    [told_new, told_leads]
  end

  @doc """
  The customer joined (`:added`) or left (`:removed`) a team: that team's
  leads, never the actor. "Fiza moved Tanweer into Backend squad."
  """
  @spec team_changed(Scope.t(), map(), map(), :added | :removed, DateTime.t()) :: list()
  def team_changed(%Scope{} = scope, customer, team, what, %DateTime{} = now) do
    who = actor_name(scope)

    title =
      case what do
        :added -> "#{who} moved #{customer.display_name} into #{team.name}"
        :removed -> "#{who} took #{customer.display_name} out of #{team.name}"
      end

    for user_id <- leads_of([team.id]), user_id != Scope.user_id(scope) do
      tell(customer, user_id, "profiles.owners_changed", now,
        title: title,
        actor: Scope.user_id(scope),
        link: "/customers/#{customer.id}",
        dedupe:
          "customer:#{customer.id}:team:#{team.id}:#{what}:#{DateTime.to_unix(now, :microsecond)}"
      )
    end
  end

  defp owners_of(customer) do
    case Map.get(customer, :profiles) do
      profiles when is_list(profiles) ->
        for p <- profiles, is_nil(p.archived_at), m <- p.profile_members, do: m.user_id

      _not_loaded ->
        case Data.Customers.get(customer.organisation_id, customer.id) do
          nil -> []
          loaded -> owners_of(loaded)
        end
    end
  end

  # The customer's teams, read fresh: a preloaded customer may not carry them.
  defp team_ids(customer) do
    case Data.Customers.get(customer.organisation_id, customer.id) do
      nil -> []
      loaded -> loaded.team_ids
    end
  end

  defp leads_of(team_ids) do
    for team_id <- team_ids, m <- Teams.list_members(team_id), m.role == :lead, do: m.user_id
  end

  defp actor_name(scope) do
    case Scope.user_id(scope) && Accounts.get_user(Scope.user_id(scope)) do
      %{} = user -> Person.first_name(user) || "Someone"
      _none -> "The team"
    end
  end

  defp hash(what), do: :erlang.phash2(what)

  defp tell(customer, user_id, kind, now, opts) do
    {:ok, row} =
      Notifications.ensure(
        Scope.system(%{id: customer.organisation_id}),
        %{
          organisation_id: customer.organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          actor_user_id: opts[:actor],
          title: opts[:title],
          link_path: opts[:link],
          dedupe_key: opts[:dedupe]
        },
        now
      )

    if row.is_new,
      do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
