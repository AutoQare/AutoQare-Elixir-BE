defmodule Data.Behaviour.Watch do
  @moduledoc """
  A person's watch on a company or a contact (AQ-10 §5, §8): a trigger,
  the channels beyond the bell it may use, a cool-down in minutes, an
  expiry, when it last fired and whether it is paused. Its owner's own.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Companies.Company
  alias Data.Contacts.Contact
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @triggers Vocabulary.watch_triggers() |> Enum.map(&String.to_atom/1)
  @channels Vocabulary.delivery_channels() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "watches" do
    field(:trigger, Ecto.Enum, values: @triggers)
    field(:channels, {:array, Ecto.Enum}, values: @channels, default: [])
    field(:cooldown_minutes, :integer, default: 120)
    field(:expires_at, :utc_datetime_usec)
    field(:last_fired_at, :utc_datetime_usec)
    field(:paused_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)
    belongs_to(:company, Company)
    belongs_to(:contact, Contact)

    timestamps()
  end

  @doc "A new watch: its owner, its subject and its trigger, then its settings."
  def create_changeset(watch, attrs) do
    watch
    |> cast(attrs, [:organisation_id, :user_id, :company_id, :contact_id, :trigger])
    |> validate_required([:organisation_id, :user_id, :trigger])
    |> settings(attrs)
    |> check_constraint(:trigger, name: :trigger_known)
    |> check_constraint(:company_id, name: :one_subject, message: "needs exactly one subject")
    |> unique_constraint(:trigger,
      name: :watches_user_company_trigger_index,
      message: "is watched already"
    )
    |> unique_constraint(:trigger,
      name: :watches_user_contact_trigger_index,
      message: "is watched already"
    )
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:contact_id)
  end

  @doc "Its settings: channels, cool-down, expiry, paused."
  def settings_changeset(watch, attrs), do: watch |> change() |> settings(attrs)

  defp settings(changeset, attrs) do
    changeset
    |> cast(attrs, [:channels, :cooldown_minutes, :expires_at, :paused_at])
    |> validate_required([:cooldown_minutes])
    |> validate_number(:cooldown_minutes, greater_than: 0)
    |> check_constraint(:channels, name: :channels_known)
    |> check_constraint(:trigger, name: :trigger_known)
  end

  @doc "When it fired."
  def fired_changeset(watch, %DateTime{} = at), do: change(watch, last_fired_at: at)
end
