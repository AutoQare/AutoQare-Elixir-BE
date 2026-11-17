defmodule Core.Imports.People do
  @moduledoc """
  The people an import brings (AQ-12 §11.4, QP12-12): a row's recruiter —
  matched by handle like any contact (`Core.Contacts`), made with `source:
  import` when nobody holds the handles, and linked to the lead — and a
  contacts import's rows, made or filled (blank title, notes and company;
  every field with `overwrite`). Called inside `Core.Imports.Write`'s
  transaction.
  """

  alias Core.Companies
  alias Core.Contacts
  alias Core.Imports.{Fill, Write}
  alias Core.Leads.Ledger
  alias Data.Contacts, as: ContactStore
  alias Data.Leads, as: LeadStore
  alias Data.Scope

  # ── The recruiter ───────────────────────────────────────────────────────────

  @doc """
  The row's recruiter matched or made by handle (a LinkedIn, a work and a
  personal email: one contact) and linked to `lead` as its recruiter, the
  link credited like the application; `only_if_none: true` leaves a lead
  that has a recruiter already. Answers `%{"contact_ids" => made,
  "linked" => [id]}`.
  """
  @spec recruiter(Scope.t(), map(), map(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def recruiter(%Scope{} = scope, ctx, lead, values, %DateTime{} = now, opts \\ []) do
    r = values["recruiter"] || %{}

    handles =
      valid_handles(linkedin: r["linkedin"], email: r["email"], email: r["personal_email"])

    cond do
      handles == [] ->
        {:ok, %{"contact_ids" => [], "linked" => []}}

      opts[:only_if_none] && ContactStore.for_lead(lead.id) != [] ->
        {:ok, %{"contact_ids" => [], "linked" => []}}

      true ->
        with {:ok, contact, made} <-
               find_or_make(scope, recruiter_name(r, handles), lead.job.company_id, handles, now),
             :ok <- link(scope, ctx, lead, contact, values, now) do
          {:ok, %{"contact_ids" => made, "linked" => [contact.id]}}
        end
    end
  end

  defp valid_handles(pairs) do
    for {kind, value} <- pairs,
        value,
        {:ok, [handle]} <- [Contacts.handles([%{"kind" => to_string(kind), "value" => value}])],
        uniq: true,
        do: handle
  end

  defp recruiter_name(%{"name" => name}, _handles) when is_binary(name), do: name

  # No name in the sheet: the LinkedIn slug's words ("sara-khan" → "Sara
  # Khan"), else the address's ("sara.k@…" → "Sara K").
  defp recruiter_name(_r, handles) do
    words =
      case Enum.find(handles, &(&1.kind == :linkedin)) || hd(handles) do
        %{kind: :linkedin, normalized: "linkedin:" <> slug} -> slug
        %{value: value} -> value |> String.split("@") |> hd()
      end

    words
    |> String.split(~r/[^\p{L}]+/u, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> Utils.presence() || "Recruiter"
  end

  defp find_or_make(scope, name, company_id, handles, now) do
    case Contacts.assess(scope, name, company_id, handles) do
      %{answer: :exact, contact: contact} ->
        {:ok, contact, []}

      _new_or_possible ->
        params = %{"name" => name, "company_id" => company_id}

        case Contacts.insert(scope, params, name, handles, now, source: "import") do
          {:ok, {_how, contact}} -> {:ok, contact, [contact.id]}
          {:error, _reason} = error -> error
        end
    end
  end

  defp link(scope, _ctx, lead, contact, values, now) do
    case ContactStore.lead_contact(lead.id, contact.id) do
      nil ->
        attrs = %{
          lead_id: lead.id,
          contact_id: contact.id,
          role: :recruiter,
          linked_by_user_id: Scope.user_id(scope)
        }

        with {:ok, _link} <- ContactStore.link_lead(attrs) do
          labels = %{
            contact_id: contact.id,
            to_label: "#{contact.name} · Recruiter",
            actor_kind: :import,
            actor_user_id: values["applier_user_id"] || Scope.user_id(scope)
          }

          _event = Ledger.record(scope, LeadStore.reload(lead), :contact_linked, labels, now)
          :ok
        end

      _held ->
        :ok
    end
  end

  # ── Contacts ────────────────────────────────────────────────────────────────

  @doc "A contacts row: made (`source: import`) or, for a handle a contact holds, its blanks filled."
  @spec contact(Scope.t(), map(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def contact(%Scope{} = scope, ctx, values, %DateTime{} = now) do
    handles =
      valid_handles(email: values["email"], linkedin: values["linkedin"], phone: values["phone"])

    case Contacts.assess(scope, values["name"], nil, handles) do
      %{answer: :exact, contact: held} ->
        fill_contact(scope, ctx, held, values, now)

      _new_or_possible ->
        params =
          %{"title" => values["title"], "notes_md" => values["notes"]}
          |> Map.merge(
            if values["company"], do: %{"company" => %{"name" => values["company"]}}, else: %{}
          )

        case Contacts.insert(scope, params, values["name"], handles, now, source: "import") do
          {:ok, {_how, made}} ->
            {:ok,
             %{
               job_id: nil,
               lead_id: nil,
               created: %{"contact_ids" => [made.id], "lead" => nil},
               replaced: %{}
             }}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp fill_contact(scope, ctx, contact, values, now) do
    plan = Fill.contact(contact, values, ctx.overwrite)

    attrs =
      Map.new(plan, fn
        {"contacts.company_id", name} ->
          {:company_id, Companies.find_or_insert(scope, %{"name" => name}, now).id}

        {"contacts." <> column, value} ->
          {String.to_existing_atom(column), value}
      end)

    with {:ok, _contact} <-
           if(attrs == %{}, do: {:ok, contact}, else: ContactStore.update(contact, attrs)) do
      replaced = Map.new(plan, fn {key, _v} -> {key, Write.old(contact, key)} end)

      filled =
        Map.new(plan, fn {"contacts." <> column = key, _v} ->
          {key, attrs[String.to_existing_atom(column)]}
        end)

      {:ok,
       %{
         job_id: nil,
         lead_id: nil,
         created: %{
           "contact_ids" => [],
           "lead" => nil,
           "contact" => contact.id,
           "filled" => filled
         },
         replaced: replaced
       }}
    end
  end
end
