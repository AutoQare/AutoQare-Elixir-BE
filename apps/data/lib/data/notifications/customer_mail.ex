defmodule Data.Notifications.CustomerMail do
  @moduledoc """
  One email for a customer with no portal login (AQ-10B §11.4, QP10b-2):
  `core` writes the words (`subject`, the plain `text`, a meeting's
  `ics`); the delivery sweep renders the designed email from them, sends
  it and keeps what it sent (`html`, `text`). Unique by `dedupe_key`.
  """

  use Data.Schema

  @states Data.Vocabulary.customer_mail_states() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "customer_mail" do
    belongs_to(:organisation, Data.Organisations.Organisation)
    belongs_to(:customer, Data.Customers.Customer)
    field(:kind_key, :string)
    field(:dedupe_key, :string)
    field(:to_email, :string)
    field(:subject, :string)
    field(:html, :string)
    field(:text, :string)
    field(:ics, :string)
    field(:state, Ecto.Enum, values: @states, default: :pending)
    field(:attempts, :integer, default: 0)
    field(:error, :string)
    field(:sent_at, :utc_datetime_usec)

    timestamps()
  end
end
