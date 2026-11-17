defmodule Core.Dashboards.Rules do
  @moduledoc """
  What each number counts (AQ-11 §4, QP11-4…6), in one place, **pure**:
  the kinds `Data.Dashboards` is handed. Stage kinds are the engine's (a
  custom stage counts as its anchor, as the ledger writes it).

  | Word | Is |
  |---|---|
  | **A response** | an employer's reply (`message_in` not from the customer), reaching a stage past *Applied* — past the waiting kinds `applied` and `seen`, P4b's follow-up rule (`Core.Leads.FollowUps`) — or the outcome *Rejected* or *Position closed* |
  | **An interview** | reaching `assessment · interview · ai_interview · final`, or a meeting of the kinds that offer those stages (`technical · assessment_review · ai_interview · final`, `Core.Meetings.Sheet`) that is scheduled, done or a no-show |
  | **An offer** | reaching `offer · negotiation · contract` |
  | **Hired** | the outcome *Hired* |
  """

  @interview_kinds [:assessment, :interview, :ai_interview, :final]
  @offer_kinds [:offer, :negotiation, :contract]
  @response_kinds [:screening | @interview_kinds ++ @offer_kinds]

  @doc "The kinds the counter is handed."
  @spec counting() :: map()
  def counting do
    %{
      response_kinds: @response_kinds,
      interview_kinds: @interview_kinds,
      offer_kinds: @offer_kinds,
      answer_outcomes: [:rejected, :position_closed],
      interview_meetings: [:technical, :assessment_review, :ai_interview, :final],
      meeting_statuses: [:scheduled, :done, :no_show]
    }
  end
end
