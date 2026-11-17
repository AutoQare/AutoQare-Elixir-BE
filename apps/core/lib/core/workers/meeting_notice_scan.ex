defmodule Core.Workers.MeetingNoticeScan do
  @moduledoc """
  Meetings still unconfirmed 24 hours before, and meetings with no outcome
  30 minutes after their end (AQ-10B §5.5 M5, M6): every ten minutes on
  the `scheduling` queue. Holds no rule (`Core.Notifications.Scans.meetings/1`);
  idempotent by each meeting's dedupe key.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Notifications.Scans

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _did = Scans.meetings(Clock.now())
    :ok
  end
end
