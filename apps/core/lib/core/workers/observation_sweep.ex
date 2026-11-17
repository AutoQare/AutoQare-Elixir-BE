defmodule Core.Workers.ObservationSweep do
  @moduledoc """
  Observations past the organisation's `observation_retention_days`,
  deleted (AQ-10 §9, §11.4). **Daily**, on the `retention` queue; the hour
  counts stay. Holds no rule — it hands the clock to
  `Core.Behaviour.Privacy.sweep/1` — and is idempotent: a second run
  deletes nothing. `POST /team/v1/dev/sweeps` runs the same on a dev
  server.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Behaviour.Privacy
  alias Core.Clock

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _deleted = Privacy.sweep(Clock.now())
    :ok
  end
end
