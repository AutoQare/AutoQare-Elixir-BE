defmodule Data.Repo.Migrations.CreateLeadWatchers do
  use Ecto.Migration

  @moduledoc """
  *Watch* on a lead (AQ-10B §6, §11.4, QP10b-15; PLAN §11's lead
  watchers): a staff member told of the lead's replies and moves as its
  owner is. One row per lead and person; gone with either.
  """

  def change do
    create table(:lead_watchers, primary_key: false) do
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:lead_watchers, [:user_id]))
  end
end
