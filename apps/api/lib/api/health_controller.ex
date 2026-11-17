defmodule Api.HealthController do
  @moduledoc """
  The root `GET /health` (DEPLOY-PLAN L7): is this backend up, and does its
  database answer? Jenkins' check curls it after a deploy, and so can a
  person.

      200 {"status": "ok",       "db": "ok",   "version": "42"}
      503 {"status": "degraded", "db": "down", "version": "42"}

  Unauthenticated, like `/info`, and it says nothing a stranger could use:
  no host, no error text (the reason goes to the log). `version` is the
  release's (`RELEASE_VSN`, which `bin/autoqare` exports, and Jenkins sets to
  its build number through `RELEASE_VERSION`), else the compiled one.

  **Its own body, not the house error shape**: a probe's answer is a state,
  not a refusal with a code, and Jenkins reads `status`. `/info` stays as it
  is: which build, with no database round trip.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  # Read at compile time: a release has no Mix.
  @version Mix.Project.config()[:version]

  def show(conn, _params) do
    {status, body} = report(Data.Repo.ping(), version())

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc """
  The answer for a ping's result, pure: `{http_status, body}`.

      iex> Api.HealthController.report(:ok, "7")
      {200, %{status: "ok", db: "ok", version: "7"}}
  """
  @spec report(:ok | {:error, term()}, String.t()) :: {200 | 503, map()}
  def report(:ok, version), do: {200, %{status: "ok", db: "ok", version: version}}

  def report({:error, reason}, version) do
    Logger.warning("GET /health: the database did not answer: #{inspect(reason)}")
    {503, %{status: "degraded", db: "down", version: version}}
  end

  @doc "The running release's version, else the compiled one."
  @spec version() :: String.t()
  def version do
    case System.get_env("RELEASE_VSN") do
      vsn when is_binary(vsn) and vsn != "" -> vsn
      _not_a_release -> @version
    end
  end
end
