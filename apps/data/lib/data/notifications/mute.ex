defmodule Data.Notifications.Mute do
  @moduledoc """
  A person's mute of a lead or of a customer (AQ-10B §11.4, QP10b-3):
  exactly one subject, one per person and subject.
  """

  use Data.Schema

  @type t :: %__MODULE__{}

  schema "notification_mutes" do
    belongs_to(:organisation, Data.Organisations.Organisation)
    belongs_to(:user, Data.Accounts.User)
    belongs_to(:lead, Data.Leads.Lead)
    belongs_to(:customer, Data.Customers.Customer)
    field(:inserted_at, :utc_datetime_usec)
  end
end
