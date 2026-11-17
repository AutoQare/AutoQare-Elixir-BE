defmodule ApiShared.Refusal do
  @moduledoc """
  The words of a refusal, apart from its response: `describe/1` (the bulk
  answer's `{code, message}`) and the sentences `ApiShared.FallbackController`
  builds for its clauses. **The codes and statuses stay the fallback's**;
  this holds only words, so the fallback stays one readable table.
  """

  require Logger

  alias Core.Approvals.Sheet, as: ApprovalSheet
  alias Core.Leads.Words, as: LeadWords
  alias Ecto.Changeset

  @doc """
  A refusal as `{code, message}` without a response: what `POST /leads/bulk`
  lists for each lead it could not act on (AQ-04B §8.1, QP4b-19). The same
  codes and words as `ApiShared.FallbackController`'s clauses, for the
  reasons a lead verb gives.
  """
  @spec describe(term()) :: %{code: String.t(), message: String.t()}
  def describe(%Changeset{} = changeset),
    do: field_words(ApiShared.FallbackController.errors_on(changeset))

  def describe({:missing, fields}),
    do: field_words(Map.new(List.wrap(fields), &{&1, ["is required"]}))

  def describe({:invalid, details}) when is_map(details), do: field_words(details)
  def describe(:not_found), do: %{code: "not_found", message: "We could not find that."}

  def describe({:forbidden, words}) when is_binary(words),
    do: %{code: "forbidden", message: words}

  def describe({:lead_moved, %{state: state} = lead}) do
    stage = Map.get(lead, :stage)

    %{
      code: "lead_moved",
      message:
        "This lead moved while you were looking. It's now " <>
          LeadWords.place(state, stage && Map.get(stage, :name), Map.get(lead, :outcome)) <> "."
    }
  end

  def describe({:duplicate_application, %{message: message}}),
    do: %{code: "duplicate_application", message: message}

  def describe(:outcome_required), do: %{code: "outcome_required", message: "Say how it ended."}

  def describe({:approval_not_pending, %{state: state}}),
    do: %{code: "approval_not_pending", message: approval_words(state)}

  def describe(:not_reviewer), do: %{code: "not_reviewer", message: "This isn't yours to decide."}

  def describe(:forget_not_allowed),
    do: %{code: "forget_not_allowed", message: "Only a team lead can forget someone."}

  def describe(:override_reason_required),
    do: %{code: "override_reason_required", message: "Say why you're applying again."}

  def describe(reason) do
    Logger.error("Unhandled bulk refusal: #{inspect(reason)}")
    %{code: "internal_error", message: "Something went wrong at our end."}
  end

  @doc "A pending approval that moved on (AQ-07 §4)."
  @spec approval_words(atom() | String.t()) :: String.t()
  def approval_words(state),
    do:
      "This approval changed while you were looking. It's now #{ApprovalSheet.state_words(state)}."

  @doc "A handle another contact holds (AQ-06 §6)."
  @spec contact_words(atom() | nil, String.t()) :: String.t()
  def contact_words(kind, name) do
    handle =
      case kind do
        :email -> "email"
        :linkedin -> "LinkedIn"
        :upwork -> "Upwork account"
        :indeed -> "Indeed account"
        :fiverr -> "Fiverr account"
        :phone -> "phone number"
        _other -> "handle"
      end

    "That #{handle} is #{name}'s already."
  end

  # ── Imports (AQ-12 §11.4) ───────────────────────────────────────────────────

  @doc "422 `import_unreadable` with nothing more to say."
  @spec unreadable_words() :: String.t()
  def unreadable_words, do: "We couldn't read that file. Upload a .csv or an .xlsx file."

  @doc "409 `import_not_ready`: the import is somewhere else in its life."
  @spec import_not_ready_words(atom() | String.t()) :: String.t()
  def import_not_ready_words(state),
    do: "This import isn't ready to run: it's #{state_words(state)}."

  @doc "409 `import_not_undoable`: nothing to undo, or undone already."
  @spec not_undoable_words(atom() | String.t()) :: String.t()
  def not_undoable_words(state),
    do: "This import can't be undone: it's #{state_words(state)}."

  @doc """
  A count as written.

      iex> ApiShared.Refusal.count(20_000)
      "20,000"
  """
  @spec count(integer()) :: String.t()
  def count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @state_words %{
    "reading" => "still reading the file",
    "mapping" => "waiting for its columns to be mapped",
    "checking" => "still checking the rows",
    "ready" => "ready to import",
    "importing" => "importing now",
    "imported" => "imported already",
    "undoing" => "being undone",
    "undone" => "undone already",
    "failed" => "failed"
  }

  defp state_words(state), do: Map.get(@state_words, to_string(state), to_string(state))

  defp field_words(details) do
    message =
      Enum.map_join(details, " ", fn {field, messages} ->
        "#{String.capitalize(String.replace(to_string(field), "_", " "))} #{Enum.join(List.wrap(messages), ", ")}."
      end)

    %{code: "validation_failed", message: message}
  end
end
