defmodule Core.Workers.NotificationScan do
  @moduledoc """
  The hourly notification scans (AQ-10B §5, §11.4): invitations' reminders
  and expiry, untouched leads, stale triage, silent forwarding, leads
  purged soon, watches ending and the system admin's checks, on the
  `scheduling` queue. Holds no rule (`Core.Notifications.Scans.hourly/1`);
  idempotent, each row ensured by a dedupe key.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Notifications.Scans

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _did = Scans.hourly(Clock.now())
    :ok
  end
end
