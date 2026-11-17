defmodule Core.Workers.ImportStep do
  @moduledoc """
  One background step of an import (AQ-12 §11.4, QP12-15) — `read`,
  `check`, `commit` or `undo` — on the `ingest` queue, as the person who
  started it. Holds no rule: it hands the clock to
  `Core.Imports.Steps.run/4`, which does nothing for an import no longer in
  the step's state, so a second run is harmless.
  """

  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias Core.Access.Grants
  alias Core.Clock
  alias Core.Imports.Steps
  alias Data.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => id, "step" => step, "user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil -> :ok
      user -> Steps.run(Grants.scope_for(user, via: :task), id, step, Clock.now())
    end
  end
end
