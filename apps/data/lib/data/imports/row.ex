defmodule Data.Imports.Row do
  @moduledoc """
  One row of an import's file (AQ-12 §11.4): its tab and sheet row number,
  the `cells` as read, the mapped `values`, the dry run's `result` and
  `reasons` (`[%{"code", "words"}]`); once imported, its job and lead, what
  it `created` (`%{"job", "lead", "company", "contact_ids"}`) and the old
  value of every field it filled (`replaced`, `%{"table.column" => old}`).
  JSON with string keys throughout.
  """

  use Data.Schema

  alias Data.Vocabulary

  @results Vocabulary.import_row_results() |> Enum.map(&String.to_atom/1)

  @fields ~w(import_id tab row_number cells values result reasons job_id lead_id created
             replaced)a

  @type t :: %__MODULE__{}

  schema "import_rows" do
    field(:tab, :string)
    field(:row_number, :integer)
    field(:cells, :map, default: %{})
    field(:values, :map, default: %{})
    field(:result, Ecto.Enum, values: @results)
    field(:reasons, {:array, :map}, default: [])
    field(:created, :map, default: %{})
    field(:replaced, :map, default: %{})

    belongs_to(:import, Data.Imports.Import)
    belongs_to(:job, Data.Jobs.Job)
    belongs_to(:lead, Data.Leads.Lead)

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:import_id, :tab, :row_number])
    |> validate_number(:row_number, greater_than_or_equal_to: 1)
    |> check_constraint(:result, name: :result_known)
    |> check_constraint(:row_number, name: :row_number_positive)
    |> unique_constraint([:import_id, :tab, :row_number])
    |> foreign_key_constraint(:import_id)
  end
end
