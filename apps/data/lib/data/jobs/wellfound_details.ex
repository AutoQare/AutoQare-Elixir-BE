defmodule Data.Jobs.WellfoundDetails do
  @moduledoc """
  What Wellfound shows about a job (AQ-12 §5, §11.4, QP12-21), as written:
  the company's stage, its remote policy, the time zones it expects and its
  visa line. Salary and equity are the job's own ranges.
  """

  use Data.Schema

  @primary_key false
  @fields ~w(company_stage_text remote_policy_text timezone_text visa_text)a

  @type t :: %__MODULE__{}

  schema "job_wellfound_details" do
    field(:job_id, :binary_id, primary_key: true)
    field(:company_stage_text, :string)
    field(:remote_policy_text, :string)
    field(:timezone_text, :string)
    field(:visa_text, :string)

    timestamps()
  end

  @doc "The platform's columns, as the sheet lists them."
  def fields, do: @fields

  def changeset(details, attrs) do
    Enum.reduce(@fields, cast(details, attrs, @fields), &validate_length(&2, &1, max: 200))
  end
end
