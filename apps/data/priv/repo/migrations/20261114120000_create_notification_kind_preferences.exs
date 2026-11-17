defmodule Data.Repo.Migrations.CreateNotificationKindPreferences do
  use Ecto.Migration

  @moduledoc """
  A person's switches for one notification kind (AQ-10B §11.4, QP10b-3):
  push, email, the extension and the digest, beside the group's
  (`notification_preferences`). **Off at either level is off.** A row is
  written the first time a person changes a kind's switch, holding every
  channel as it then stood; no row means the kind's defaults (its
  channels on, the offered ones off).

  A person's own, like their group switches: gone with the person, and
  with the kind.
  """

  def change do
    create table(:notification_kind_preferences, primary_key: false) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :notification_kind_key,
        references(:notification_kinds, column: :key, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:is_push_on, :boolean, null: false, default: true)
      add(:is_email_on, :boolean, null: false, default: true)
      add(:is_extension_on, :boolean, null: false, default: true)
      add(:is_digest_on, :boolean, null: false, default: true)
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:notification_kind_preferences, [:notification_kind_key]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON notification_kind_preferences " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON notification_kind_preferences"
    )
  end
end
