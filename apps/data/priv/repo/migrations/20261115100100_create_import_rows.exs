defmodule Data.Repo.Migrations.CreateImportRows do
  use Ecto.Migration

  @moduledoc """
  One row of an import's file (AQ-12 §11.4): its tab and sheet row number
  (unique in the import), the `cells` as read (header → text) and the
  `values` the mapping read from them; the dry run's `result` (`new ·
  update · duplicate · error · skipped`) with its `reasons` (`[{code,
  words}]`). Once imported, the job and lead it is about, what it
  `created` (`{job, lead, company, contact_ids}`) and the old value of
  every field it filled (`replaced`, `{"table.column": old}`), which is
  what undo deletes and puts back (QP12-14). Each key is nilified when its
  row goes, so an undo or a later delete never fails on it.
  """

  @results ~w(new update duplicate error skipped)

  def change do
    create table(:import_rows, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:import_id, references(:imports, type: :uuid, on_delete: :delete_all), null: false)
      add(:tab, :text, null: false)
      add(:row_number, :integer, null: false)
      add(:cells, :jsonb, null: false, default: "{}")
      add(:values, :jsonb, null: false, default: "{}")
      add(:result, :text)
      add(:reasons, :jsonb, null: false, default: "[]")
      add(:job_id, references(:jobs, type: :uuid, on_delete: :nilify_all))
      add(:lead_id, references(:leads, type: :uuid, on_delete: :nilify_all))
      add(:created, :jsonb, null: false, default: "{}")
      add(:replaced, :jsonb, null: false, default: "{}")

      timestamps()
    end

    create(
      constraint(:import_rows, :result_known,
        check: "result IS NULL OR result IN (#{Enum.map_join(@results, ",", &"'#{&1}'")})"
      )
    )

    create(constraint(:import_rows, :row_number_positive, check: "row_number >= 1"))
    create(unique_index(:import_rows, [:import_id, :tab, :row_number]))
    create(index(:import_rows, [:job_id]))
    create(index(:import_rows, [:lead_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON import_rows " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON import_rows"
    )
  end
end
