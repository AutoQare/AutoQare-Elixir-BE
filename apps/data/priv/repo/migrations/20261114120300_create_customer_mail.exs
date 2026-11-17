defmodule Data.Repo.Migrations.CreateCustomerMail do
  use Ecto.Migration

  @moduledoc """
  Mail for a customer with no portal login (AQ-10B §11.4, QP10b-2): they
  have no bell, so no notification row; only an email, and only for a
  meeting scheduled, changed or tomorrow (with its `.ics`), a milestone
  and the weekly report. `core` and `notifire` never call each other, so
  `core` writes the words (`subject`, the plain `text`, a meeting's `ics`)
  and the delivery sweep renders the designed email from them, sends it
  and keeps what it sent (`html`, `text`).

  `dedupe_key` is unique, so a scan or a retried verb writes it once.
  `state` ∈ `pending · sent · failed · skipped`; a failure keeps its
  `error` (at most 500 characters) and counts `attempts`.
  """

  @states ~w(pending sent failed skipped)

  def change do
    create table(:customer_mail, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(
        :kind_key,
        references(:notification_kinds, column: :key, type: :string, on_delete: :restrict),
        null: false
      )

      add(:dedupe_key, :text, null: false)
      add(:to_email, :text, null: false)
      add(:subject, :text, null: false)
      add(:html, :text)
      add(:text, :text, null: false)
      add(:ics, :text)
      add(:state, :text, null: false, default: "pending")
      add(:attempts, :smallint, null: false, default: 0)
      add(:error, :text)
      add(:sent_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:customer_mail, :state_known,
        check: "state IN (#{Enum.map_join(@states, ",", &"'#{&1}'")})"
      )
    )

    create(
      constraint(:customer_mail, :sent_with_time,
        check: "(state = 'sent') = (sent_at IS NOT NULL)"
      )
    )

    create(
      constraint(:customer_mail, :error_short,
        check: "error IS NULL OR char_length(error) <= 500"
      )
    )

    create(constraint(:customer_mail, :attempts_counted, check: "attempts >= 0"))
    create(unique_index(:customer_mail, [:dedupe_key]))
    create(index(:customer_mail, [:organisation_id]))
    create(index(:customer_mail, [:customer_id]))
    create(index(:customer_mail, [:kind_key]))

    create(
      index(:customer_mail, [:inserted_at],
        where: "state = 'pending'",
        name: :customer_mail_pending_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON customer_mail " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON customer_mail"
    )
  end
end
