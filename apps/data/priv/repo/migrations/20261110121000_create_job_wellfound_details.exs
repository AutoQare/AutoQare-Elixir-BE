defmodule Data.Repo.Migrations.CreateJobWellfoundDetails do
  use Ecto.Migration

  @moduledoc """
  What Wellfound shows about a job (AQ-12 §5, §11.4, QP12-21), one row per
  job at most, each as written on the page: the company's stage
  ("Series A"), its remote policy ("Remote only"), the time zones it
  expects and what it says about visas. Salary and equity go to the job's
  own ranges, not here.
  """

  def change do
    create table(:job_wellfound_details, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:company_stage_text, :string)
      add(:remote_policy_text, :string)
      add(:timezone_text, :string)
      add(:visa_text, :string)

      timestamps()
    end

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON job_wellfound_details " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON job_wellfound_details"
    )
  end
end
