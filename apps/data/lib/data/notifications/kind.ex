defmodule Data.Notifications.Kind do
  @moduledoc """
  An event that raises a notification (AQ-02 §5.2, §8), with its default
  channels: `default_channels` the staff's, `customer_channels` the
  customer's (`nil`: the same; P10b, AQ-10B §11.4). An empty list means
  the kind is not for that audience. `is_locked` (QP10b-4): can't be
  switched off, passes quiet hours and snooze.
  """

  use Data.Schema

  alias Data.Notifications.Group

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "notification_kinds" do
    field(:default_channels, {:array, :string}, default: ["inapp"])
    field(:customer_channels, {:array, :string})
    field(:can_ignore_quiet_hours, :boolean, default: false)
    field(:is_locked, :boolean, default: false)

    belongs_to(:notification_group, Group,
      foreign_key: :notification_group_key,
      references: :key,
      type: :string
    )
  end

  @doc """
  The kind's channels for an audience: the staff's, or the customer's.

      iex> Data.Notifications.Kind.channels(%{default_channels: ~w(inapp push), customer_channels: nil}, true)
      ["inapp", "push"]
      iex> Data.Notifications.Kind.channels(%{default_channels: [], customer_channels: ~w(inapp email)}, false)
      []
  """
  @spec channels(map(), boolean()) :: [String.t()]
  def channels(%{customer_channels: nil, default_channels: channels}, true), do: channels
  def channels(%{customer_channels: channels}, true), do: channels
  def channels(%{default_channels: channels}, false), do: channels

  def changeset(kind, attrs) do
    kind
    |> cast(attrs, [
      :key,
      :notification_group_key,
      :default_channels,
      :customer_channels,
      :can_ignore_quiet_hours,
      :is_locked
    ])
    |> validate_required([:key, :notification_group_key])
    |> check_constraint(:key, name: :key_names_its_group)
    |> check_constraint(:default_channels, name: :default_channels_known)
    |> check_constraint(:customer_channels, name: :customer_channels_known)
    |> check_constraint(:default_channels, name: :for_someone)
    |> foreign_key_constraint(:notification_group_key)
  end
end
