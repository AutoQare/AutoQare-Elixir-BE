defmodule Autoqare.Release do
  @moduledoc """
  Migrating and seeding a built release, which has no Mix (DEPLOY-PLAN L1,
  D-3; tCart's `TCart.Release`).

  ## On a server

  From the site directory (`~/sites/<api host>`), with its `.env` sourced so
  the release reads the same variables as the running app (`bin/autoqare
  eval` boots `config/runtime.exs` too, so it refuses without them):

      cd ~/sites/<api host> && source .env

      builds/bin/autoqare eval "Autoqare.Release.migrate()"     # every deploy (the jobs run it)
      builds/bin/autoqare eval "Autoqare.Release.status()"      # which migrations are up
      builds/bin/autoqare eval "Autoqare.Release.rollback(20261101000000)"
      builds/bin/autoqare eval "Autoqare.Release.seed()"        # the production seed, idempotent
      builds/bin/autoqare eval 'Autoqare.Release.bootstrap("Regbits BD", "admin@example.com", "Name")'
      builds/bin/autoqare eval "Autoqare.Release.seed_standard()"  # remote dev only (D-9)

  **Seeding is a separate call, on purpose**, never part of `migrate/0`: a
  deploy migrates automatically, and what gets seeded is somebody's decision.

  Each loads the apps without starting them (no endpoint, no Oban queues, no
  crontab), starts the Repo through `Ecto.Migrator.with_repo/2` and stops it
  after: migrations must not need a web server, and starting one during a
  migration is how deploys deadlock. What the running server does later
  (the invitation's mail, an Oban job) is only inserted here.
  """

  alias Core.Organisation
  alias Core.Organisation.Invitations
  alias Core.Standard
  alias Data.Scope
  alias Data.Seeds

  # `:ecto_repos` is `data`'s config, whichever app this compiles into.
  @app :data
  # Loaded, never started: `Application.app_dir/2` (a seed's `priv` file)
  # raises for an application that is merely on the code path.
  @apps [:utils, :data, :core, :notifire, :api]

  # D-9: the standard set's password, the user's rule (2026-11-12).
  @standard_password "password123"

  @doc "Runs every pending migration. Idempotent: a migrated database runs none."
  @spec migrate() :: [integer()]
  def migrate do
    load_app()

    Enum.flat_map(repos(), fn repo ->
      {:ok, versions, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

      versions
    end)
  end

  @doc "Rolls the database back to `version` (that migration stays up)."
  @spec rollback(integer()) :: [integer()]
  def rollback(version) when is_integer(version) do
    load_app()

    {:ok, versions, _apps} =
      Ecto.Migrator.with_repo(hd(repos()), &Ecto.Migrator.run(&1, :down, to: version))

    versions
  end

  @doc """
  Which migrations are up and which are not, printed and returned: a release
  has no `mix ecto.migrations`, and the first time somebody wants it is
  halfway through a deploy.
  """
  @spec status() :: [{atom(), integer(), String.t()}]
  def status do
    load_app()

    {:ok, migrations, _apps} = Ecto.Migrator.with_repo(hd(repos()), &Ecto.Migrator.migrations/1)

    Enum.each(migrations, fn {state, version, name} ->
      IO.puts("#{state |> to_string() |> String.pad_trailing(6)} #{version}  #{name}")
    end)

    migrations
  end

  @doc """
  The production seed, exactly what `mix aq.prod_seed` runs
  (`Data.Seeds.run(:prod)`): the reference lists, the skills vocabulary,
  the default pipelines and settings. No accounts. Idempotent by key.
  """
  @spec seed() :: [{String.t(), term()}]
  def seed do
    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo -> Seeds.quietly(&prod_seed/0) end)

    case result do
      {:ok, results} ->
        IO.puts("Production seed: " <> Seeds.summary(:prod, results))
        results

      {:error, why} ->
        raise "The production seed failed: #{why}"
    end
  end

  defp prod_seed, do: Seeds.run(:prod, [])

  @doc """
  The organisation and its first admin's invitation (`mix aq.bootstrap`,
  through `Core.Organisation.bootstrap/2`). With SES the invitation is
  emailed and only its address printed; with `MAILER_ADAPTER=local` (or no
  mailer) the accept link is printed instead (`prints_link?/0`), so a link
  never lands in a Jenkins log on a box that can mail it.

  **Idempotent like the Mix task**: run again while the invitation is open,
  it says the organisation exists and sends the invitation again (or prints
  the link again); a lapsed one is re-issued. Once somebody holds the system
  admin role it raises, saying how to hand it on.
  """
  @spec bootstrap(String.t(), String.t(), String.t()) :: map()
  def bootstrap(org, admin_email, admin_name)
      when is_binary(org) and is_binary(admin_email) and is_binary(admin_name) do
    params = %{org_name: org, admin_email: admin_email, admin_name: admin_name}

    params
    |> then(&with_writes(fn -> Organisation.bootstrap(&1, Core.Clock.now()) end))
    |> case do
      {:ok, result} ->
        report_bootstrap(result)
        result

      {:error, :admin_exists} ->
        raise "The organisation already has its system admin. Hand the role on with " <>
                "mix aq.admin --to <email> (a dev checkout), not another bootstrap."

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "Could not bootstrap: #{inspect(changeset.errors)}"

      {:error, reason} ->
        raise "Could not bootstrap: #{inspect(reason)}"
    end
  end

  # **The accept link is printed only where nothing else would deliver it.**
  # Jenkins runs this, so what it prints lands in a job log, and the link
  # takes the admin account. With a real mailer (`MAILER_ADAPTER=ses`) the
  # invitation goes by email as the front door sends it (`Invitations.issue/3`
  # enqueues the mail job; the running server works it) and only the address
  # is printed. With `local`, or no mailer configured, the link is printed,
  # as `mix aq.bootstrap` does.
  defp report_bootstrap(%{organisation: organisation, invitation: invitation} = result) do
    if result.organisation_created?,
      do: IO.puts("Created the organisation #{organisation.name} (#{organisation.slug})."),
      else:
        IO.puts("The organisation #{organisation.name} (#{organisation.slug}) already exists.")

    case result.status do
      :issued -> IO.puts("Invited #{invitation.email} as an admin.")
      :reissued -> IO.puts("Re-issued the lapsed admin invitation for #{invitation.email}.")
      :open -> IO.puts("An admin invitation for #{invitation.email} is already open.")
    end

    if prints_link?() do
      IO.puts("No mail leaves this box (MAILER_ADAPTER=local), so here is the link.")
      IO.puts("Accept link: #{Invitations.accept_url(invitation)}")
    else
      IO.puts("Invitation sent to #{invitation.email} (the server's mail queue delivers it).")
    end

    IO.puts("Expires: #{DateTime.to_iso8601(invitation.expires_at)}")
  end

  @doc """
  Whether `bootstrap/3` prints the accept link: only when no mail would
  carry it, Swoosh's local mailbox or no mailer at all.
  """
  @spec prints_link?() :: boolean()
  def prints_link? do
    adapter = :notifire |> Application.get_env(Notifire.Mailer, []) |> Keyword.get(:adapter)
    adapter in [nil, Swoosh.Adapters.Local]
  end

  @doc """
  The standard test set (`Core.Standard`, `docs/TEST-ACCOUNTS.md`), every
  account on `password123`. Idempotent; after `bootstrap/3` for Super Admin
  it accepts that invitation.

  **Refuses unless this release allows test passwords**
  (`AQ_ALLOW_TEST_PASSWORDS=true`, D-9: remote dev only), which is also what
  lets the worst-list accept `password123`. Staging and production never
  set it, so there this raises and writes nothing.
  """
  @spec seed_standard() :: map()
  def seed_standard do
    unless test_passwords_allowed?() do
      raise """
      The standard test set is refused: this release does not allow test passwords.

      Only remote dev sets AQ_ALLOW_TEST_PASSWORDS=true in its .env (DEPLOY-PLAN D-9);
      staging and production never do.
      """
    end

    case with_writes(fn ->
           Standard.ensure(Scope.system(), @standard_password, Core.Clock.now())
         end) do
      {:ok, summary} ->
        report_standard(summary)
        summary

      {:error, words} when is_binary(words) ->
        raise words

      {:error, reason} ->
        raise "Could not ensure the standard set: #{inspect(reason)}"
    end
  end

  @doc "Whether this node accepts the standard test password (D-9's switch, set by runtime.exs)."
  @spec test_passwords_allowed?() :: boolean()
  def test_passwords_allowed?, do: Application.get_env(:core, :dev_worst_passwords, false) == true

  defp report_standard(%{made: made, kept: kept}) do
    case made do
      [] -> IO.puts("Standard set: all #{kept} already in place; made nothing.")
      _some -> IO.puts("Standard set: made #{length(made)}, kept #{kept}.")
    end

    IO.puts("  Every account signs in with the standard test password (docs/TEST-ACCOUNTS.md):")

    for account <- Standard.accounts() do
      IO.puts("    #{String.pad_trailing(account.email, 26)} #{account.role}")
    end
  end

  # ── Running the front door's code without the server ───────────────────────

  # The Repo, Oban for inserts only (an invitation's mail is a job the running
  # server works), and broadcasts off when no endpoint runs here: nobody is
  # on a socket to this node, and `Api.Endpoint.broadcast/3` needs a started
  # endpoint. Inside a running node (the suite) both are left as they are.
  defp with_writes(work) do
    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        :ok = ensure_oban()
        without_endpoint(fn -> Seeds.quietly(work) end)
      end)

    result
  end

  # `:oban` first: `Oban.whereis/1` reads a registry the application owns.
  defp ensure_oban do
    {:ok, _started} = Application.ensure_all_started(:oban)

    if Oban.whereis(Oban) do
      :ok
    else
      {:ok, _oban} = Oban.start_link(repo: Data.Repo, queues: false, plugins: false, peer: false)
      :ok
    end
  end

  defp without_endpoint(work) do
    endpoint = Application.get_env(:core, :endpoint)

    if endpoint && Process.whereis(endpoint) do
      work.()
    else
      Application.put_env(:core, :endpoint, nil)

      try do
        work.()
      after
        Application.put_env(:core, :endpoint, endpoint)
      end
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # Loads the apps without starting them. **The timezone database is
  # started and proven** (tCart's lesson): an eval node starts almost
  # nothing, and a zone lookup without `tz` returns an error for every zone
  # but UTC, which the seeds' day math would otherwise half-survive.
  defp load_app do
    Enum.each(@apps, &Application.load/1)
    {:ok, _started} = Application.ensure_all_started(:tz)

    case DateTime.now("Europe/London") do
      {:ok, _now} -> :ok
      {:error, reason} -> raise "The timezone database is not available (#{inspect(reason)})."
    end
  end
end
