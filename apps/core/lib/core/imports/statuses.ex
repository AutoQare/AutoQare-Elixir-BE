defmodule Core.Imports.Statuses do
  @moduledoc """
  Where an imported application stands (AQ-12 §3.3, QP12-6), pure.

  | Old status | State · stage · outcome |
  |---|---|
  | Applied, Follow-up due, Followed up, No response (recent) | In progress · Applied |
  | Responded, Info requested | In progress · Screening |
  | Interview scheduled, Interviewing | In progress · the pipeline's first interview stage |
  | Assessment | In progress · Assessment |
  | Offer | In progress · Offer |
  | Placed | Done · Hired |
  | Rejected | Done · Rejected |
  | Position closed | Done · Position closed |
  | No response (older than the cut-off) | Done · No response |

  **With no status** (QP12-6): applied within the organisation's
  no-response cut-off (`no_response_days`, 14) → In progress · Applied;
  older → Done · No response, dated at the applied day plus the cut-off.
  A status off the table is read as none, and says so (`:unknown`).

  A place is `%{state, stage_kind, outcome, at_days}`: `stage_kind` the
  engine kind to stand at (`nil` keeps the first `applied` stage),
  `at_days` how many days after the applied day the place is dated.
  """

  @statuses %{
    "applied" => :applied,
    "follow up due" => :applied,
    "followup due" => :applied,
    "follow up" => :applied,
    "followed up" => :applied,
    "no response" => :no_response,
    "responded" => :screening,
    "info requested" => :screening,
    "information requested" => :screening,
    "screening" => :screening,
    "interview scheduled" => :interview,
    "interviewing" => :interview,
    "interview" => :interview,
    "assessment" => :assessment,
    "test" => :assessment,
    "offer" => :offer,
    "placed" => :hired,
    "hired" => :hired,
    "rejected" => :rejected,
    "position closed" => :position_closed,
    "closed" => :position_closed
  }

  @type place :: %{
          state: :in_progress | :done,
          stage_kind: atom() | nil,
          outcome: atom() | nil,
          at_days: non_neg_integer()
        }

  @doc "Whether a status as written is on §3.3's table (blank is none, and fine)."
  @spec known?(String.t() | nil) :: boolean()
  def known?(status) do
    case words(status) do
      "" -> true
      words -> Map.has_key?(@statuses, words)
    end
  end

  @doc """
  The place of an application made on `applied_on`, at `today`, with
  `cutoff` the no-response days.

      iex> Core.Imports.Statuses.place(nil, ~D[2026-11-10], ~D[2026-11-15], 14)
      %{state: :in_progress, stage_kind: nil, outcome: nil, at_days: 0}
      iex> Core.Imports.Statuses.place("", ~D[2024-10-09], ~D[2026-11-15], 14)
      %{state: :done, stage_kind: nil, outcome: :no_response, at_days: 14}
      iex> Core.Imports.Statuses.place("Interviewing", ~D[2024-10-09], ~D[2026-11-15], 14)
      %{state: :in_progress, stage_kind: :interview, outcome: nil, at_days: 0}
  """
  @spec place(String.t() | nil, Date.t(), Date.t(), pos_integer()) :: place()
  def place(status, %Date{} = applied_on, %Date{} = today, cutoff) do
    old? = Date.diff(today, applied_on) > cutoff

    case Map.get(@statuses, words(status)) do
      kind when kind in [nil, :no_response] -> if old?, do: no_response(cutoff), else: applied()
      :applied -> applied()
      kind when kind in [:hired, :rejected, :position_closed] -> done(kind)
      kind -> %{state: :in_progress, stage_kind: kind, outcome: nil, at_days: 0}
    end
  end

  defp applied, do: %{state: :in_progress, stage_kind: nil, outcome: nil, at_days: 0}
  defp done(outcome), do: %{state: :done, stage_kind: nil, outcome: outcome, at_days: 0}

  defp no_response(cutoff),
    do: %{state: :done, stage_kind: nil, outcome: :no_response, at_days: cutoff}

  defp words(nil), do: ""

  defp words(status) do
    status
    |> String.downcase()
    |> String.replace(~r/[^a-z]+/, " ")
    |> String.trim()
  end
end
