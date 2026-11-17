defmodule Core.Imports.Sheet do
  @moduledoc """
  An import and its rows as the console reads them (AQ-12 §11.4); the JSON
  is `ApiShared.ImportsJSON`'s.

  - `import`: `{id, team, file_name, kind, state, progress, tabs: [{name,
    rows, profile?, applier?, include}], columns: [{header, sample,
    field}], fields: [{key, label, required}], date_order, overwrite,
    counts (all ten), by, inserted_at, checked_at, imported_at,
    undo_until, undone_at, error_text, can: {map, commit, undo}}`;
  - `row`: `{id, tab, row_number, cells, values, result, reasons, job?,
    lead?}`.
  """

  alias Core.Imports.Fields
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Imports.{Import, Row}
  alias Data.Profiles

  @counts ~w(new update duplicate error skipped created updated removed restored kept)

  @doc "The import, at `now` (what `can.undo` reads)."
  @spec view(Import.t(), DateTime.t()) :: map()
  def view(%Import{} = import, %DateTime{} = now) do
    %{
      id: import.id,
      team: %{id: import.team.id, name: import.team.name},
      file_name: import.file_name,
      kind: import.kind,
      state: import.state,
      progress: import.progress,
      tabs: Enum.map(import.tabs, &tab/1),
      columns: columns(import),
      fields: Fields.view(import.kind),
      date_order: import.date_order,
      overwrite: import.overwrite,
      counts: Map.new(@counts, &{&1, Map.get(import.counts || %{}, &1, 0)}),
      by: Person.view(import.created_by_user),
      inserted_at: import.inserted_at,
      checked_at: import.checked_at,
      imported_at: import.imported_at,
      undo_until: import.undo_until,
      undone_at: import.undone_at,
      error_text: import.error_text,
      can: can(import, now)
    }
  end

  @doc "What may be done now: map (and re-check), import, undo."
  @spec can(Import.t(), DateTime.t()) :: map()
  def can(%Import{state: state} = import, now) do
    %{
      map: state in [:mapping, :ready],
      commit: state == :ready,
      undo:
        state == :imported and not is_nil(import.undo_until) and
          not DateTime.after?(now, import.undo_until)
    }
  end

  @doc "A row."
  @spec row(Row.t()) :: map()
  def row(%Row{} = row) do
    %{
      id: row.id,
      tab: row.tab,
      row_number: row.row_number,
      cells: row.cells,
      values: row.values,
      result: row.result,
      reasons: row.reasons,
      job: job(row),
      lead: row.lead_id && %{id: row.lead_id}
    }
  end

  defp job(%Row{job: %{id: id, title: title}}), do: %{id: id, title: title}
  defp job(_row), do: nil

  defp tab(tab) do
    %{
      name: tab["name"],
      rows: tab["rows"],
      profile: profile(tab["profile_id"]),
      applier: tab["applier_user_id"] && Person.view(Accounts.get_user(tab["applier_user_id"])),
      include: tab["include"] != false
    }
  end

  defp profile(nil), do: nil

  defp profile(id) do
    case Profiles.get(id) do
      nil -> nil
      p -> %{id: p.id, title: p.title, customer_name: p.customer.display_name}
    end
  end

  # Every header across the tabs, in the order first met, with the first
  # sample a tab has for it and the field it maps to.
  defp columns(%Import{tabs: tabs, mapping: mapping}) do
    tabs
    |> Enum.flat_map(&(&1["headers"] || []))
    |> Enum.uniq()
    |> Enum.map(fn header ->
      %{
        header: header,
        sample: Enum.find_value(tabs, "", &Utils.presence(get_in(&1, ["samples", header]) || "")),
        field: Map.get(mapping || %{}, header, "ignore")
      }
    end)
  end
end
