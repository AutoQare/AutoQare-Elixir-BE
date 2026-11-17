defmodule Data.Behaviour.Observation do
  @moduledoc """
  What was seen of a company or a contact (AQ-10 §5, §11.4): exactly one
  subject, a kind, when it was seen (`observed_at`) and when the subject
  was active (`active_at`), where it came from, who saw it and, for job
  and signal facts, the job; for a reply, the message and its delay.
  Written once (`Data.Behaviour.insert_observation/1`): a second capture
  of the same fact meets a unique key and writes nothing.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Companies.Company
  alias Data.Contacts.Contact
  alias Data.Conversations.Message
  alias Data.Jobs.Job
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @kinds Vocabulary.observation_kinds() |> Enum.map(&String.to_atom/1)
  @sources Vocabulary.observation_sources() |> Enum.map(&String.to_atom/1)

  @fields ~w(organisation_id company_id contact_id kind observed_at active_at source
             observer_user_id job_id message_id reply_delay_s note request_id inserted_at)a

  @type t :: %__MODULE__{}

  schema "observations" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:observed_at, :utc_datetime_usec)
    field(:active_at, :utc_datetime_usec)
    field(:source, Ecto.Enum, values: @sources)
    field(:reply_delay_s, :integer)
    field(:note, :string)
    field(:request_id, :string)
    field(:inserted_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:company, Company)
    belongs_to(:contact, Contact)
    belongs_to(:observer_user, User)
    belongs_to(:job, Job)
    belongs_to(:message, Message)
  end

  @doc "The kinds, as atoms."
  def kinds, do: @kinds

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, @fields)
    |> validate_required([
      :organisation_id,
      :kind,
      :observed_at,
      :active_at,
      :source,
      :inserted_at
    ])
    |> validate_subject()
    |> validate_length(:note, max: 500)
    |> validate_length(:request_id, max: 100)
    |> validate_number(:reply_delay_s, greater_than_or_equal_to: 0)
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:source, name: :source_known)
    |> check_constraint(:company_id, name: :one_subject, message: "needs exactly one subject")
    |> check_constraint(:reply_delay_s, name: :reply_delay_on_replied)
    |> check_constraint(:note, name: :note_by_hand)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:contact_id)
  end

  defp validate_subject(changeset) do
    case {get_field(changeset, :company_id), get_field(changeset, :contact_id)} do
      {nil, nil} ->
        add_error(changeset, :company_id, "needs exactly one subject")

      {company, contact} when is_binary(company) and is_binary(contact) ->
        add_error(changeset, :company_id, "needs exactly one subject")

      _one ->
        changeset
    end
  end
end
