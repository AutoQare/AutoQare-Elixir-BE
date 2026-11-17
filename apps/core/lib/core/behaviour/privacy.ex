defmodule Core.Behaviour.Privacy do
  @moduledoc """
  Kept to what a pattern or a watch needs (AQ-10 §9, P10.5, QP10-15…17):

  - **Retention** (`sweep/1`): observations seen longer ago than the
    organisation's `observation_retention_days` (180 by default; Settings
    › System edits it) are deleted. `subject_hours` stays: the roll-up.
  - ***Forget this person*** (`forget_contact/3`): the contact's
    observations, hour counts and watches deleted, the contact marked
    `is_do_not_contact`, one audit row. ***Forget its people***
    (`forget_people/3`) does the same for each contact of a company; the
    company's own posting history stays (a business, not a person).
    A team lead of a team touching the subject, or the system admin
    (403 `forget_not_allowed` for staff who see it, 404 for anyone else).
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Audit
  alias Core.Behaviour
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Behaviour, as: Store
  alias Data.Contacts
  alias Data.Contacts.Contact
  alias Data.Repo
  alias Data.Scope

  @doc """
  `POST /contacts/:id/forget`: answers the contact as `GET /contacts/:id`
  does (P6's shape with its `behaviour`), now do-not-contact.
  """
  @spec forget_contact(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def forget_contact(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, subject} <- Behaviour.subject(scope, :forget, :contact, id),
         {:ok, contact} <- Write.commit(fn -> forget(scope, subject.record, now) end) do
      behaviour = Behaviour.summary_for(scope, :contact, contact.id, now)

      {:ok,
       scope |> Core.Contacts.view(Contacts.reload(contact)) |> Map.put(:behaviour, behaviour)}
    end
  end

  @doc "`POST /companies/:id/forget-people`: `{forgotten}`, how many contacts."
  @spec forget_people(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def forget_people(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, subject} <- Behaviour.subject(scope, :forget, :company, id) do
      people =
        Repo.all(
          from(c in Contact,
            where: c.company_id == ^subject.id and c.organisation_id == ^subject.organisation_id,
            order_by: [asc: c.id]
          )
        )

      Write.commit(fn -> {:ok, %{forgotten: length(people)}, forget_all(scope, people, now)} end)
    end
  end

  defp forget_all(scope, people, now) do
    for person <- people do
      {:ok, _contact, events} = forget(scope, person, now)
      events
    end
  end

  defp forget(scope, %Contact{} = contact, now) do
    # AQ-10B §5.7 B2: the watchers told before their watches go.
    ending =
      contact.id |> Data.Watches.on_contact_for_system() |> Core.Watches.ending(:forgotten, now)

    gone = Store.forget_contact(contact.id)

    with {:ok, updated} <- Contacts.update(contact, %{is_do_not_contact: true}) do
      {:ok, _event} =
        Audit.record(scope, "forgotten", updated,
          before: %{"is_do_not_contact" => contact.is_do_not_contact},
          after: %{
            "is_do_not_contact" => true,
            "observations" => gone.observations,
            "hours" => gone.hours,
            "watches" => gone.watches
          },
          now: now
        )

      key = {:contact, contact.id}

      {:ok, updated,
       [ending | Enum.map(Store.team_ids(key), &Realtime.observation_added(&1, key))]}
    end
  end

  @doc """
  The daily sweep: each organisation's observations seen before its
  retention, deleted. Idempotent: a second run at the same `now` deletes
  nothing. Answers `%{deleted}`.
  """
  @spec sweep(DateTime.t()) :: map()
  def sweep(%DateTime{} = now) do
    deleted =
      for {organisation_id, days} <- Store.retention_for_system(), reduce: 0 do
        n ->
          n +
            Store.delete_seen_before(organisation_id, DateTime.add(now, -days * 86_400, :second))
      end

    %{deleted: deleted}
  end
end
