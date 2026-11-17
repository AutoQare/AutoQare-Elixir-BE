defmodule Data.Repo.Migrations.CreateNotificationKinds do
  use Ecto.Migration

  @moduledoc """
  Every event that raises a notification (AQ-02 §5.2, §8; tCart's):
  `tasks.assigned`, `tasks.overdue`. The key names its group, and a CHECK
  holds the two together. `default_channels` are PLAN §11's, seeded now so
  P8 reads them without a migration; in-app is always among them.

  **P10b (AQ-10B §11.4, QP10b-1, QP10b-4):** `default_channels` are the
  staff's and `customer_channels` the customer's (`null`: the same as the
  staff's). An empty list means the kind is not for that audience (a
  customer's milestone is never a staff notice). `is_locked` marks the
  security kinds nobody can switch off, which pass quiet hours and snooze.
  """

  def change do
    create table(:notification_kinds, primary_key: false) do
      add(:key, :string, primary_key: true)

      add(
        :notification_group_key,
        references(:notification_groups, column: :key, type: :string, on_delete: :restrict),
        null: false
      )

      add(:default_channels, {:array, :string}, null: false, default: ["inapp"])
      add(:customer_channels, {:array, :string})
      add(:can_ignore_quiet_hours, :boolean, null: false, default: false)
      add(:is_locked, :boolean, null: false, default: false)
    end

    create(
      constraint(:notification_kinds, :key_names_its_group,
        check:
          "key ~ '^[a-z_]+\\.[a-z0-9_]+$' AND starts_with(key, notification_group_key || '.')"
      )
    )

    create(
      constraint(:notification_kinds, :default_channels_known,
        check:
          "default_channels <@ ARRAY['inapp','push','email','extension','digest']::varchar[] " <>
            "AND (cardinality(default_channels) = 0 OR 'inapp' = ANY(default_channels))"
      )
    )

    create(
      constraint(:notification_kinds, :customer_channels_known,
        check:
          "customer_channels IS NULL OR (customer_channels <@ " <>
            "ARRAY['inapp','push','email','digest']::varchar[] " <>
            "AND (cardinality(customer_channels) = 0 OR 'inapp' = ANY(customer_channels)))"
      )
    )

    create(
      constraint(:notification_kinds, :for_someone,
        check:
          "cardinality(default_channels) > 0 OR coalesce(cardinality(customer_channels), 0) > 0"
      )
    )

    create(index(:notification_kinds, [:notification_group_key]))
  end
end
