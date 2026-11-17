defmodule Data.Repo.Migrations.CreateImports do
  use Ecto.Migration

  @moduledoc """
  An import (AQ-12 §3, §11.4): one uploaded `.csv` or `.xlsx` brought into
  one team, by a team lead of it or the system admin. `kind` says what the
  file holds (`applications · jobs · contacts`, QP12-3); `state` walks
  `reading → mapping → checking → ready → importing → imported`, then
  `undoing → undone` once, or `failed` with its `error_text`.

  `tabs` is the file's tabs as read, each with what the Map step chose:
  `[{name, rows, profile_id, applier_user_id, include}]` (QP12-4, QP12-5);
  `mapping` is `{header: field}`; `date_order` reads `10/9/2026`
  (QP12-8, day/month by default); `overwrite` lets the import replace
  values already there (QP12-10, off). `counts` keeps the dry run's and
  the import's and undo's numbers; `progress` (0–100) is what the
  background jobs report. `undo_until` is seven days after `imported_at`
  (QP12-14).
  """

  @kinds ~w(applications jobs contacts)
  @states ~w(reading mapping checking ready importing imported undoing undone failed)

  def change do
    create table(:imports, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :restrict), null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:media_id, references(:media, type: :uuid, on_delete: :nilify_all))
      add(:file_name, :text, null: false)
      add(:kind, :text, null: false)
      add(:state, :text, null: false, default: "reading")
      add(:tabs, :jsonb, null: false, default: "[]")
      add(:mapping, :jsonb, null: false, default: "{}")
      add(:date_order, :text, null: false, default: "day_month")
      add(:overwrite, :boolean, null: false, default: false)
      add(:counts, :jsonb, null: false, default: "{}")
      add(:progress, :smallint, null: false, default: 0)
      add(:error_text, :text)
      add(:checked_at, :timestamptz)
      add(:imported_at, :timestamptz)
      add(:undo_until, :timestamptz)
      add(:undone_at, :timestamptz)

      timestamps()
    end

    create(constraint(:imports, :kind_known, check: "kind IN (#{list(@kinds)})"))
    create(constraint(:imports, :state_known, check: "state IN (#{list(@states)})"))

    create(
      constraint(:imports, :date_order_known, check: "date_order IN ('day_month','month_day')")
    )

    create(constraint(:imports, :progress_range, check: "progress BETWEEN 0 AND 100"))

    create(
      constraint(:imports, :file_name_present,
        check: "btrim(file_name) <> '' AND char_length(file_name) <= 255"
      )
    )

    create(index(:imports, [:organisation_id]))

    create(
      index(:imports, [:team_id, "inserted_at DESC"], name: :imports_team_id_inserted_at_index)
    )

    create(index(:imports, [:created_by_user_id]))
    create(index(:imports, [:media_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON imports " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON imports"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
