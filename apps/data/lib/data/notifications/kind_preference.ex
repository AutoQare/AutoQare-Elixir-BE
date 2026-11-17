defmodule Data.Notifications.KindPreference do
  @moduledoc """
  A person's switches for one kind (AQ-10B §11.4, QP10b-3), beside the
  group's (`Data.Notifications.Preference`): off at either level is off.
  No row means the kind's defaults: its channels on, its offered ones off
  (`Data.Seeds.Notifications.offered/2`).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Notifications.Kind

  @primary_key false

  @type t :: %__MODULE__{}

  schema "notification_kind_preferences" do
    belongs_to(:user, User, primary_key: true)

    belongs_to(:notification_kind, Kind,
      foreign_key: :notification_kind_key,
      references: :key,
      type: :string,
      primary_key: true
    )

    field(:is_push_on, :boolean, default: true)
    field(:is_email_on, :boolean, default: true)
    field(:is_extension_on, :boolean, default: true)
    field(:is_digest_on, :boolean, default: true)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "The switches as `%{push, email, extension, digest}`."
  @spec switches(t()) :: %{atom() => boolean()}
  def switches(%__MODULE__{} = p),
    do: %{
      push: p.is_push_on,
      email: p.is_email_on,
      extension: p.is_extension_on,
      digest: p.is_digest_on
    }
end
