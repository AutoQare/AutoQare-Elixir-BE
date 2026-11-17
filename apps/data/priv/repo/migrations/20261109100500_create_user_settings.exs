defmodule Data.Repo.Migrations.CreateUserSettings do
  use Ecto.Migration

  @moduledoc """
  A person's settings, 1:1 with their account (AQ-01 §4.1): the theme, quiet
  hours (null = off) and the daily digest. **Code defaults when no row**
  (tCart's pattern): a new account renders a screen before anybody opens
  the settings page. The notification groups' preferences come in P8.

  **P10b (AQ-10B §11.4, QP10b-3, QP10b-12):** `digest_frequency` (`daily ·
  weekly · off`; weekly goes on Monday) replaces `digest_on`, and
  `snoozed_until` is *Pause notifications*: push, pop-ups and email held to
  that moment while the bell fills.
  """

  @digest_frequencies ~w(daily weekly off)

  def change do
    create table(:user_settings, primary_key: false) do
      # The user id *is* the primary key, which is what makes this 1:1.
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:theme, :string, null: false, default: "system")
      add(:quiet_hours_start, :time)
      add(:quiet_hours_end, :time)
      add(:digest_time, :time, null: false, default: "08:00:00")
      add(:digest_frequency, :text, null: false, default: "daily")
      add(:snoozed_until, :timestamptz)

      timestamps()
    end

    create(constraint(:user_settings, :theme_known, check: "theme IN ('system','light','dark')"))

    create(
      constraint(:user_settings, :digest_frequency_known,
        check: "digest_frequency IN (#{Enum.map_join(@digest_frequencies, ",", &"'#{&1}'")})"
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON user_settings " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON user_settings"
    )
  end
end
