defmodule Data.Repo.Migrations.CreateNotificationMutes do
  use Ecto.Migration

  @moduledoc """
  A person's mute of a lead or of a customer's whole pipeline (AQ-10B §6,
  §11.4, QP10b-3), staff only. A muted subject writes **no notification
  row at all** for that person, except a mention, an approval asked of
  them and a meeting about to start. Tasks keep their own mute
  (`task_participants.is_muted`). Exactly one subject; one mute per person
  and subject.
  """

  def change do
    create table(:notification_mutes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all))
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:notification_mutes, :one_subject,
        check: "num_nonnulls(lead_id, customer_id) = 1"
      )
    )

    create(
      unique_index(:notification_mutes, [:user_id, :lead_id],
        where: "lead_id IS NOT NULL",
        name: :notification_mutes_user_lead_index
      )
    )

    create(
      unique_index(:notification_mutes, [:user_id, :customer_id],
        where: "customer_id IS NOT NULL",
        name: :notification_mutes_user_customer_index
      )
    )

    create(index(:notification_mutes, [:user_id]))
    create(index(:notification_mutes, [:organisation_id]))
    create(index(:notification_mutes, [:lead_id]))
    create(index(:notification_mutes, [:customer_id]))
  end
end
