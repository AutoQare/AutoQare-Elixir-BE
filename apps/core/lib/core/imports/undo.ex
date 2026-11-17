defmodule Core.Imports.Undo do
  @moduledoc """
  One imported row undone (AQ-12 §11.4, QP12-14), in its own transaction;
  `Core.Imports.Steps` walks the rows in reverse.

  - A lead the import made is **deleted outright** — no fingerprint, so
    the guard forgets it — unless it has an event, a note, a task, a label
    or a change since (`Data.Imports.lead_touched?/1`): then it is kept,
    and counted.
  - A job it made goes when no other lead holds it and nobody changed it.
  - Contacts it made go when nothing else links them; a company it made
    when no job or contact names it. A recruiter it linked to a lead that
    stays is unlinked.
  - Every `replaced` value is put back where the field still holds what
    the import wrote.

  Answers the row's tally: `%{removed, restored, kept}`.
  """

  alias Core.Imports.Write
  alias Core.Tasks.Write, as: Tx
  alias Data.Contacts, as: ContactStore
  alias Data.Imports, as: Store
  alias Data.Imports.Row
  alias Data.JobParts
  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: LeadStore
  alias Data.Retention
  alias Data.Scope

  @zero %{removed: 0, restored: 0, kept: 0}

  @doc "Undoes `row`: `{:ok, %{removed, restored, kept}}`, or the error that rolled it back."
  @spec row(Scope.t(), Row.t()) :: {:ok, map()} | {:error, term()}
  def row(%Scope{} = scope, %Row{} = row) do
    Tx.commit(fn ->
      created = row.created || %{}
      org = Scope.organisation_id(scope)

      tally =
        @zero
        |> lead(org, created["lead"])
        |> unlink(row.lead_id, created["lead"], created["linked"] || [])
        |> restore(org, row)
        |> job(org, created["job"])
        |> contacts(created["contact_ids"] || [])
        |> company(created["company"])

      {:ok, tally}
    end)
  end

  defp lead(tally, _org, nil), do: tally

  defp lead(tally, org, lead_id) do
    case LeadStore.get(org, lead_id) do
      nil ->
        tally

      lead ->
        if Store.lead_touched?(lead.id) do
          bump(tally, :kept)
        else
          {:ok, _gone} = Retention.delete_lead(lead)
          bump(tally, :removed)
        end
    end
  end

  # A recruiter the import linked to a lead that was there before it (an
  # `update` row's) is unlinked; a kept lead the import made keeps its.
  defp unlink(tally, lead_id, nil, linked) when is_binary(lead_id) do
    Enum.each(linked, fn contact_id ->
      case ContactStore.lead_contact(lead_id, contact_id) do
        nil -> :ok
        link -> {:ok, _gone} = ContactStore.unlink_lead(link)
      end
    end)

    tally
  end

  defp unlink(tally, _lead_id, _made, _linked), do: tally

  defp job(tally, _org, nil), do: tally

  defp job(tally, org, job_id) do
    case JobStore.get(org, job_id) do
      nil ->
        tally

      job ->
        if Store.job_held?(job.id, []) do
          tally
        else
          {:ok, _gone} = JobStore.delete(job)
          bump(tally, :removed)
        end
    end
  end

  defp contacts(tally, ids) do
    Enum.reduce(ids, tally, fn id, acc ->
      if Store.contact_held?(id) do
        acc
      else
        :ok = Store.delete_contact(id)
        bump(acc, :removed)
      end
    end)
  end

  defp company(tally, nil), do: tally

  defp company(tally, id) do
    if Store.company_held?(id) do
      tally
    else
      :ok = Store.delete_company(id)
      bump(tally, :removed)
    end
  end

  # ── Fills put back ──────────────────────────────────────────────────────────

  defp restore(tally, org, %Row{replaced: replaced, created: created} = row) do
    filled = (created || %{})["filled"] || %{}

    Enum.reduce(replaced || %{}, tally, fn {key, old}, acc ->
      if put_back(org, row, key, old, Map.get(filled, key)), do: bump(acc, :restored), else: acc
    end)
  end

  defp put_back(org, row, "jobs." <> _column = key, old, wrote) do
    case row.job_id && JobStore.get(org, row.job_id) do
      %{} = job -> job_back(job, key, old, wrote)
      _gone -> false
    end
  end

  defp put_back(org, row, "contacts." <> column = key, old, wrote) do
    with id when is_binary(id) <- (row.created || %{})["contact"],
         %{} = contact <- ContactStore.get(org, id),
         true <- same?(Write.old(contact, key), wrote) do
      {:ok, _contact} = ContactStore.update(contact, %{String.to_existing_atom(column) => old})
      true
    else
      _not_ours -> false
    end
  end

  defp job_back(job, "jobs.skills", old, wrote) do
    if same?(Write.old(job, "jobs.skills"), wrote) do
      :ok = JobParts.put_skills(job, Enum.map(old || [], &%{skill_id: &1, is_required: true}))
      true
    else
      false
    end
  end

  defp job_back(job, "jobs." <> column = key, old, wrote) do
    if same?(Write.old(job, key), wrote) do
      {:ok, _job} = JobStore.update(job, %{String.to_existing_atom(column) => old})
      true
    else
      false
    end
  end

  defp same?(now, wrote) when is_list(now) and is_list(wrote),
    do: Enum.sort(now) == Enum.sort(wrote)

  defp same?(now, wrote), do: now == wrote

  defp bump(tally, key), do: Map.update!(tally, key, &(&1 + 1))
end
