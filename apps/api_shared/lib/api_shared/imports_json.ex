defmodule ApiShared.ImportsJSON do
  @moduledoc """
  The import centre's shapes (AQ-12 §11.4), exactly as pinned; this module
  names every key, so nothing else leaks into the answer.

  - `import`: `{id, team: {id, name}, file_name, kind, state, progress,
    tabs: [{name, rows, profile: {id, title, customer_name}?, applier:
    person?, include}], columns: [{header, sample, field}], fields: [{key,
    label, required}], date_order, overwrite, counts: {new, update,
    duplicate, error, skipped, created, updated, removed, restored, kept},
    by: person, inserted_at, checked_at, imported_at, undo_until,
    undone_at, error_text, can: {map, commit, undo}}`;
  - `row`: `{id, tab, row_number, cells, values, result, reasons: [{code,
    words}], job: {id, title}?, lead: {id}?}`.
  """

  @counts ~w(new update duplicate error skipped created updated removed restored kept)
  @person [:user_id, :name, :photo_url]

  @doc "`GET /imports`: `{items: [import]}`."
  def list(%{items: items}), do: %{items: Enum.map(items, &view/1)}

  @doc "One import."
  def view(i) do
    %{
      id: i.id,
      team: Map.take(i.team, [:id, :name]),
      file_name: i.file_name,
      kind: i.kind,
      state: i.state,
      progress: i.progress,
      tabs: Enum.map(i.tabs, &tab/1),
      columns: Enum.map(i.columns, &Map.take(&1, [:header, :sample, :field])),
      fields: Enum.map(i.fields, &Map.take(&1, [:key, :label, :required])),
      date_order: i.date_order,
      overwrite: i.overwrite,
      counts: Map.new(@counts, &{&1, Map.get(i.counts, &1, 0)}),
      by: person(i.by),
      inserted_at: i.inserted_at,
      checked_at: i.checked_at,
      imported_at: i.imported_at,
      undo_until: i.undo_until,
      undone_at: i.undone_at,
      error_text: i.error_text,
      can: Map.take(i.can, [:map, :commit, :undo])
    }
  end

  @doc "`GET /imports/:id/rows`: `{items: [row], next_cursor}`."
  def rows(%{items: items, next_cursor: next}),
    do: %{items: Enum.map(items, &row/1), next_cursor: next}

  @doc "One row."
  def row(r) do
    %{
      id: r.id,
      tab: r.tab,
      row_number: r.row_number,
      cells: r.cells,
      values: r.values,
      result: r.result,
      reasons: Enum.map(r.reasons, &%{code: &1["code"], words: &1["words"]}),
      job: r.job && Map.take(r.job, [:id, :title]),
      lead: r.lead && Map.take(r.lead, [:id])
    }
  end

  defp tab(t) do
    %{
      name: t.name,
      rows: t.rows,
      profile: t.profile && Map.take(t.profile, [:id, :title, :customer_name]),
      applier: person(t.applier),
      include: t.include
    }
  end

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, @person)
end
