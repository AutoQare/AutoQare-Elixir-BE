defmodule Core.Imports.Fields do
  @moduledoc """
  What a column can map to, per kind of import (AQ-12 §11.4), and the
  guess from its header through the alias table, pure.

  | Kind | Fields |
  |---|---|
  | `applications` | `date`, `job_url`, `title`, `company`, `country`, `worldwide`, `stack`, `salary`, `platform`, `applied_by`, `profile`, `status`, `recruiter_name`, `recruiter_linkedin`, `recruiter_email`, `recruiter_personal_email`, `company_type`, `notes`, `ignore` |
  | `jobs` | the same without `date`, `applied_by`, `profile` and `status` |
  | `contacts` | `name`, `title`, `company`, `email`, `linkedin`, `phone`, `notes`, `ignore` |

  A header is read lowercased, everything but letters and digits a space;
  an alias names it exactly ("Job link", "Link", "URL" → `job_url`;
  "Applied By", "BD" → `applied_by`; "Salary Quoted", "Salary" →
  `salary`; "Sr #" → `ignore`). A header no alias names is `ignore`.
  """

  @applications ~w(date job_url title company country worldwide stack salary platform applied_by
                   profile status recruiter_name recruiter_linkedin recruiter_email
                   recruiter_personal_email company_type notes ignore)
  @jobs @applications -- ~w(date applied_by profile status)
  @contacts ~w(name title company email linkedin phone notes ignore)

  @required %{"applications" => ~w(date job_url), "jobs" => ~w(job_url), "contacts" => ~w(name)}

  @labels %{
    "date" => "Date applied",
    "job_url" => "Job link",
    "title" => "Job title",
    "company" => "Company",
    "country" => "Country",
    "worldwide" => "Worldwide",
    "stack" => "Stack",
    "salary" => "Salary",
    "platform" => "Platform",
    "applied_by" => "Applied by",
    "profile" => "Profile",
    "status" => "Status",
    "recruiter_name" => "Recruiter's name",
    "recruiter_linkedin" => "Recruiter's LinkedIn",
    "recruiter_email" => "Recruiter's email",
    "recruiter_personal_email" => "Recruiter's personal email",
    "company_type" => "Company type",
    "notes" => "Notes",
    "ignore" => "Don't import",
    "name" => "Name",
    "email" => "Email",
    "linkedin" => "LinkedIn",
    "phone" => "Phone"
  }

  # Header words → field, for the two shapes of sheet: one about
  # applications and jobs, one about people.
  @job_aliases %{
    "date" => ~w(date applied_on date_applied applied_date application_date applied_at
                 date_of_application),
    "job_url" => ~w(job_link link url job_url job_posting posting job_link_url),
    "title" => ~w(job_title title position role job designation),
    "company" => ~w(company company_name employer client organisation organization),
    "country" => ~w(country location job_location),
    "worldwide" => ~w(worldwide world_wide remote worldwide_remote),
    "stack" => ~w(stack skills tech_stack technologies tech technology),
    "salary" => ~w(salary salary_quoted rate budget compensation pay salary_range),
    "platform" => ~w(platform source site portal job_board board),
    "applied_by" => ~w(applied_by bd bd_name applier by applied_by_bd),
    "profile" => ~w(profile applied_with profile_name applied_as),
    "status" => ~w(status stage result outcome),
    "recruiter_name" => ~w(recruiter recruiter_name hr_name contact_name hiring_manager),
    "recruiter_linkedin" => ~w(recruiter_linkedin linkedin hr_linkedin recruiter_profile
                               recruiter_linkedin_url),
    "recruiter_email" => ~w(recruiter_email email hr_email contact_email work_email),
    "recruiter_personal_email" => ~w(personal_email recruiter_personal_email),
    "company_type" => ~w(company_type type),
    "notes" => ~w(notes note comments comment remarks),
    "ignore" => ~w(sr sr_no s_no serial serial_no no id)
  }

  @contact_aliases %{
    "name" => ~w(name full_name recruiter recruiter_name contact contact_name person),
    "title" => ~w(title position designation role job_title),
    "company" => ~w(company company_name employer organisation organization),
    "email" => ~w(email email_address recruiter_email work_email personal_email),
    "linkedin" => ~w(linkedin linkedin_url recruiter_linkedin profile linkedin_profile),
    "phone" => ~w(phone mobile whatsapp phone_number contact_number cell),
    "notes" => ~w(notes note comments remarks),
    "ignore" => ~w(sr sr_no s_no serial serial_no no id)
  }

  @doc "The fields a kind's columns may map to, in order."
  @spec for_kind(String.t() | atom()) :: [String.t()]
  def for_kind(kind) do
    case to_string(kind) do
      "applications" -> @applications
      "jobs" -> @jobs
      "contacts" -> @contacts
    end
  end

  @doc "The Map step's `fields`: `[%{key, label, required}]`."
  @spec view(String.t() | atom()) :: [map()]
  def view(kind) do
    required = Map.fetch!(@required, to_string(kind))
    for key <- for_kind(kind), do: %{key: key, label: @labels[key], required: key in required}
  end

  @doc """
  The field a header is guessed as, for `kind`.

      iex> Core.Imports.Fields.guess("applications", "Job link")
      "job_url"
      iex> Core.Imports.Fields.guess("applications", "Sr #")
      "ignore"
      iex> Core.Imports.Fields.guess("applications", "Salary Quoted")
      "salary"
      iex> Core.Imports.Fields.guess("contacts", "Recruiter LinkedIn")
      "linkedin"
  """
  @spec guess(String.t() | atom(), String.t()) :: String.t()
  def guess(kind, header) do
    words = words(header)
    allowed = for_kind(kind)
    aliases = if to_string(kind) == "contacts", do: @contact_aliases, else: @job_aliases

    Enum.find_value(aliases, "ignore", fn {field, names} ->
      if field in allowed and words in names, do: field
    end)
  end

  @doc "A mapping for every header, each guessed: `%{header => field}`."
  @spec guess_all(String.t() | atom(), [String.t()]) :: %{String.t() => String.t()}
  def guess_all(kind, headers), do: Map.new(headers, &{&1, guess(kind, &1)})

  @doc "Whether `field` is one a column of `kind` may map to."
  @spec known?(String.t() | atom(), term()) :: boolean()
  def known?(kind, field), do: is_binary(field) and field in for_kind(kind)

  defp words(header) do
    header
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end
end
