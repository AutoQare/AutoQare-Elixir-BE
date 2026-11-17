defmodule Core.Imports.Fill do
  @moduledoc """
  What a row would fill on a record that is there already (AQ-12 §11.4,
  QP12-10), pure: **only blank fields** — every field when the import's
  `overwrite` is on — each named `"table.column"` as `replaced` keeps it.

  | Record | Fields |
  |---|---|
  | a job | `jobs.company_id` (Company), `jobs.comp_text` (Salary), `jobs.workplace` · `jobs.remote_scope` · `jobs.allowed_countries` (Country, WORLDWIDE: "Yes" is remote worldwide, a country remote from that list), `jobs.skills` (Stack) |
  | a contact | `contacts.title`, `contacts.notes_md`, `contacts.company_id` |

  A plan is `[{key, value}]`: the value as the import writes it, a
  company by its name (found or made when written).
  """

  @labels %{
    "jobs.company_id" => "company",
    "jobs.comp_text" => "salary",
    "jobs.workplace" => "workplace",
    "jobs.remote_scope" => "remote scope",
    "jobs.allowed_countries" => "countries",
    "jobs.skills" => "skills",
    "contacts.title" => "title",
    "contacts.notes_md" => "notes",
    "contacts.company_id" => "company"
  }

  @doc "The job's columns a row's `values` fill: `[{key, value}]`."
  @spec job(map(), map(), boolean()) :: [{String.t(), term()}]
  def job(job, values, overwrite) do
    remote = remote(values)

    [
      {"jobs.company_id", values["company"], company_name(job)},
      {"jobs.comp_text", values["salary"], job.comp_text},
      {"jobs.workplace", remote[:workplace], job.workplace && to_string(job.workplace)},
      {"jobs.remote_scope", remote[:remote_scope],
       job.remote_scope && to_string(job.remote_scope)},
      {"jobs.allowed_countries", remote[:allowed_countries], blank_list(job.allowed_countries)},
      {"jobs.skills", blank_list(values["skill_ids"] || []), blank_list(skill_ids(job))}
    ]
    |> fills(overwrite)
  end

  @doc "A contact's fields a contacts row fills: `[{key, value}]`."
  @spec contact(map(), map(), boolean()) :: [{String.t(), term()}]
  def contact(contact, values, overwrite) do
    [
      {"contacts.title", values["title"], contact.title},
      {"contacts.notes_md", values["notes"], contact.notes_md},
      {"contacts.company_id", values["company"], company_name(contact)}
    ]
    |> fills(overwrite)
  end

  @doc """
  The job's place from a row: `%{workplace, remote_scope, allowed_countries}`
  as strings, or `%{}` when the row says nothing.

      iex> Core.Imports.Fill.remote(%{"worldwide" => true, "countries" => []})
      %{workplace: "remote", remote_scope: "global", allowed_countries: nil}
      iex> Core.Imports.Fill.remote(%{"worldwide" => nil, "countries" => ["US"]})
      %{workplace: "remote", remote_scope: "country_list", allowed_countries: ["US"]}
  """
  @spec remote(map()) :: map()
  def remote(values) do
    cond do
      values["worldwide"] == true ->
        %{workplace: "remote", remote_scope: "global", allowed_countries: nil}

      (values["countries"] || []) != [] ->
        %{
          workplace: "remote",
          remote_scope: "country_list",
          allowed_countries: values["countries"]
        }

      true ->
        %{}
    end
  end

  @doc "A plan in words: \"Fills company, salary.\""
  @spec words([{String.t(), term()}]) :: String.t()
  def words(plan),
    do: "Fills " <> Enum.map_join(plan, ", ", fn {key, _v} -> @labels[key] end) <> "."

  # A field the row has a value for, and that is blank (or, with
  # `overwrite`, different).
  defp fills(fields, overwrite) do
    for {key, new, old} <- fields,
        not is_nil(new),
        is_nil(old) or (overwrite and old != new),
        do: {key, new}
  end

  defp company_name(%{company: %{name: name}}), do: name
  defp company_name(_record), do: nil

  defp skill_ids(%{job_skills: skills}) when is_list(skills), do: Enum.map(skills, & &1.skill_id)
  defp skill_ids(_job), do: []

  defp blank_list([]), do: nil
  defp blank_list(list), do: list
end
