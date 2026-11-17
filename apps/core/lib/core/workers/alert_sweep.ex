defmodule Core.Workers.AlertSweep do
  @moduledoc """
  Alert jobs nobody saved, archived (AQ-12 §11.4, QP12-24): **daily**, on
  the `retention` queue. Holds no rule — it hands the clock to
  `Core.Jobs.Alerts.sweep/2`, whose rule compares `first_seen_at` with a
  cutoff 14 days back, so a missed day is caught up by the next run — and
  is idempotent: a second run archives nothing.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Clock
  alias Core.Jobs.Alerts
  alias Data.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _archived = Alerts.sweep(Scope.system(), Clock.now())
    :ok
  end
end
