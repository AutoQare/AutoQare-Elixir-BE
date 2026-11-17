defmodule Data.Repo.Migrations.CreateSubjectHours do
  use Ecto.Migration

  @moduledoc """
  The heat map's counts (AQ-10 §5, QP10-5): per subject, per hour group
  (`active · posted · replied`), per hour of the week — `weekday` 1–7
  (Monday first) and `hour` 0–23, **in UTC**, of the observation's
  `active_at`. Written in the observation's own transaction (+1). **The
  only thing kept after old observations go**: the roll-up PLAN §10.5
  promises, with no timeline of a person. *Forget* deletes a contact's.
  """

  @groups ~w(active posted replied)

  def change do
    create table(:subject_hours, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:company_id, references(:companies, type: :uuid, on_delete: :delete_all))
      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all))
      add(:kind_group, :text, null: false)
      add(:weekday, :smallint, null: false)
      add(:hour, :smallint, null: false)
      add(:count, :integer, null: false, default: 0)
    end

    create(
      constraint(:subject_hours, :kind_group_known, check: "kind_group IN (#{list(@groups)})")
    )

    create(
      constraint(:subject_hours, :one_subject, check: "num_nonnulls(company_id, contact_id) = 1")
    )

    create(constraint(:subject_hours, :weekday_range, check: "weekday BETWEEN 1 AND 7"))
    create(constraint(:subject_hours, :hour_range, check: "hour BETWEEN 0 AND 23"))
    create(constraint(:subject_hours, :count_not_negative, check: "count >= 0"))

    create(
      unique_index(:subject_hours, [:company_id, :kind_group, :weekday, :hour],
        where: "company_id IS NOT NULL",
        name: :subject_hours_company_index
      )
    )

    create(
      unique_index(:subject_hours, [:contact_id, :kind_group, :weekday, :hour],
        where: "contact_id IS NOT NULL",
        name: :subject_hours_contact_index
      )
    )

    create(index(:subject_hours, [:organisation_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
