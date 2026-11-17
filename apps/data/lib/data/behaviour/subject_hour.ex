defmodule Data.Behaviour.SubjectHour do
  @moduledoc """
  One cell of a subject's heat map (AQ-10 §5, QP10-5): how many
  observations of an hour group fell in an hour of the week — `weekday`
  1–7, Monday first, and `hour` 0–23, both in UTC. Bumped in the
  observation's transaction; kept after old observations go.
  """

  use Data.Schema

  alias Data.Companies.Company
  alias Data.Contacts.Contact
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @groups Vocabulary.hour_groups() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "subject_hours" do
    field(:kind_group, Ecto.Enum, values: @groups)
    field(:weekday, :integer)
    field(:hour, :integer)
    field(:count, :integer, default: 0)

    belongs_to(:organisation, Organisation)
    belongs_to(:company, Company)
    belongs_to(:contact, Contact)
  end
end
