defmodule Data.Repo do
  @moduledoc """
  The one Repo, owned by `data`.

  Every query in the system goes through here, and `data` is the only app that
  knows Postgres exists. `core` asks `data` for rows; the API apps render what
  `core` returns. That direction is enforced by the umbrella's dependency
  graph rather than by convention.
  """

  use Ecto.Repo,
    otp_app: :data,
    adapter: Ecto.Adapters.Postgres

  @doc """
  `SELECT 1`: `:ok` when the database answers, else `{:error, reason}`.

  The health check's question (DEPLOY-PLAN L7, `GET /health`), here because
  this is the one app that knows Postgres exists. Short on purpose: a probe
  that waits fifteen seconds for a dead database is a probe Jenkins times
  out on instead of reading.
  """
  @spec ping() :: :ok | {:error, term()}
  def ping do
    case query("SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
