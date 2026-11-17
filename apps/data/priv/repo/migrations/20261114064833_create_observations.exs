defmodule Data.Repo.Migrations.CreateObservations do
  use Ecto.Migration

  @moduledoc """
  What was seen of a company or a contact (AQ-10 §5, §11.4, QP10-1): a job
  posted or reposted, Upwork's *last viewed*, a reply and its delay,
  LinkedIn's *Active* text, Upwork presence in an open room, and by hand.
  **Exactly one subject.** `observed_at` is when it was seen; `active_at`
  when the subject was active ("Active 2 h ago" seen at 16:00 is 14:00;
  equal for `seen_online`; a reply's `sent_at`). Never page text: a note
  by hand is at most 500 characters.

  **A second capture of the same fact writes nothing:** unique `(kind,
  job_id, active_at)` for job and signal facts, `(message_id)` for
  replies, and `(organisation_id, request_id)` for the extension's
  idempotency key. Deleted after the organisation's
  `observation_retention_days` by `Core.Workers.ObservationSweep`;
  `subject_hours` keeps the counts.
  """

  @kinds ~w(seen_online last_active_reported job_posted job_reposted replied viewed_proposal
            viewed_profile message_read)
  @sources ~w(extension job email manual)

  def change do
    create table(:observations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:company_id, references(:companies, type: :uuid, on_delete: :delete_all))
      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all))
      add(:kind, :text, null: false)
      add(:observed_at, :timestamptz, null: false)
      add(:active_at, :timestamptz, null: false)
      add(:source, :text, null: false)
      add(:observer_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:job_id, references(:jobs, type: :uuid, on_delete: :nilify_all))
      add(:message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:reply_delay_s, :integer)
      add(:note, :text)
      add(:request_id, :text)
      add(:inserted_at, :timestamptz, null: false)
    end

    create(constraint(:observations, :kind_known, check: "kind IN (#{list(@kinds)})"))
    create(constraint(:observations, :source_known, check: "source IN (#{list(@sources)})"))

    create(
      constraint(:observations, :one_subject, check: "num_nonnulls(company_id, contact_id) = 1")
    )

    # A delay only on a reply, and every reply the server saw carries one;
    # a reply logged by hand may have none (QP10-18: any kind by hand).
    create(
      constraint(:observations, :reply_delay_on_replied,
        check:
          "(reply_delay_s IS NULL OR (kind = 'replied' AND reply_delay_s >= 0)) AND " <>
            "(kind <> 'replied' OR source = 'manual' OR reply_delay_s IS NOT NULL)"
      )
    )

    create(
      constraint(:observations, :note_by_hand,
        check: "note IS NULL OR (source = 'manual' AND char_length(note) <= 500)"
      )
    )

    create(
      constraint(:observations, :request_id_short,
        check: "request_id IS NULL OR char_length(request_id) <= 100"
      )
    )

    create(
      unique_index(:observations, [:kind, :job_id, :active_at],
        where: "job_id IS NOT NULL",
        name: :observations_job_fact_index
      )
    )

    create(
      unique_index(:observations, [:message_id],
        where: "message_id IS NOT NULL",
        name: :observations_message_id_index
      )
    )

    create(
      unique_index(:observations, [:organisation_id, :request_id],
        where: "request_id IS NOT NULL",
        name: :observations_request_id_index
      )
    )

    create(index(:observations, [:company_id, :active_at]))
    create(index(:observations, [:contact_id, :active_at]))
    create(index(:observations, [:organisation_id, :observed_at]))
    create(index(:observations, [:observer_user_id]))
    create(index(:observations, [:job_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
