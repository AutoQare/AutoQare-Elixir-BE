defmodule Data.Repo.Migrations.CreateWatches do
  use Ecto.Migration

  @moduledoc """
  A person's watch on a company or a contact (AQ-10 §5, §8, §11.4): a
  trigger (`comes_online · posts_job · replies · any_activity`), the
  channels beyond the bell it may use (`push · email · extension`; the
  bell always), a cool-down (30 min · 2 h · 1 day; 2 h by default), an
  expiry, when it last fired and whether it is paused. **Its owner's
  own** (PLAN §3): nobody else reads or changes it. One per person,
  subject and trigger; *Forget* deletes a contact's.
  """

  @triggers ~w(comes_online posts_job replies any_activity)
  @channels ~w(push email extension)

  def change do
    create table(:watches, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:company_id, references(:companies, type: :uuid, on_delete: :delete_all))
      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all))
      add(:trigger, :text, null: false)
      add(:channels, {:array, :text}, null: false, default: [])
      add(:cooldown_minutes, :integer, null: false, default: 120)
      add(:expires_at, :timestamptz)
      add(:last_fired_at, :timestamptz)
      add(:paused_at, :timestamptz)

      timestamps()
    end

    create(constraint(:watches, :trigger_known, check: "trigger IN (#{list(@triggers)})"))

    create(
      constraint(:watches, :channels_known,
        check: "channels <@ ARRAY[#{list(@channels)}]::text[]"
      )
    )

    create(constraint(:watches, :one_subject, check: "num_nonnulls(company_id, contact_id) = 1"))
    create(constraint(:watches, :cooldown_positive, check: "cooldown_minutes > 0"))

    create(
      unique_index(:watches, [:user_id, :company_id, :trigger],
        where: "company_id IS NOT NULL",
        name: :watches_user_company_trigger_index
      )
    )

    create(
      unique_index(:watches, [:user_id, :contact_id, :trigger],
        where: "contact_id IS NOT NULL",
        name: :watches_user_contact_trigger_index
      )
    )

    create(index(:watches, [:company_id]))
    create(index(:watches, [:contact_id]))
    create(index(:watches, [:user_id]))
    create(index(:watches, [:organisation_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON watches " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON watches"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
