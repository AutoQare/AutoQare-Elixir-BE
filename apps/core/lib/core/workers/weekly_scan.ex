defmodule Core.Workers.WeeklyScan do
  @moduledoc """
  The weekly summary and the weekly report (AQ-10B QP10b-13): every ten
  minutes on the `scheduling` queue, so Monday at each person's time
  comes round in whichever run first passes it. Holds no rule
  (`Core.Notifications.Scans.weekly/1`); idempotent by each week's dedupe
  key.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Notifications.Scans

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _did = Scans.weekly(Clock.now())
    :ok
  end
end
