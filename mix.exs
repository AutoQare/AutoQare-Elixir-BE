defmodule Autoqare.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # **`RELEASE_VERSION` is read here, not by `mix release`** (tCart's
      # note). It looks like a build-time variable and is not one: the release
      # task only consults it at *boot*, to pick which installed version to
      # start. Left as a literal, every build writes
      # `builds/autoqare-0.1.0.tar.gz` and the deploy step, which scps
      # `autoqare-$BUILD_NUMBER.tar.gz`, fails on a file that was never made.
      #
      # Unset (every local build) this is the plain project version.
      version: System.get_env("RELEASE_VERSION") || "0.1.0",
      start_permanent: Mix.env() == :prod,
      # Set here *and* in every app: umbrella children do not inherit it, so
      # the root setting alone silently protects nothing.
      elixirc_options: [warnings_as_errors: true],
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      # Phoenix 1.8 + Mix 1.20 reload through a Mix listener. Without it every
      # request in `iex -S mix phx.server` prints "a Mix listener expected by
      # Phoenix.CodeReloader is missing" and the reloader does nothing.
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        # `:cors_plug` because `Api.Endpoint` names `CORSPlug`, and `:credo`
        # because `apps/core/lib/credo/checks/max_file_length.ex` is a custom
        # check built on its behaviour.
        plt_add_apps: [:mix, :ex_unit, :cors_plug, :credo],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # `precommit` ends in `test`, so it has to run in the test environment —
  # otherwise Mix refuses with "mix test is running in the dev environment".
  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # An umbrella has no release unless one is named here: `mix release` refuses
  # rather than guessing which of the apps to start, so without this the
  # deploy pipeline fails at its build stage.
  #
  # **One release for every environment** (dev, staging, prod; DEPLOY-PLAN
  # D-2, tCart's decision). Which database it talks to, which port it listens
  # on and where its mail goes are read at boot from the target's `.env`
  # (config/runtime.exs, sample.env), never baked in, so a build is
  # promotable and the only thing distinguishing two deploys is that file.
  #
  # `path: "builds"` and the `:tar` step are what the Jenkins deploy expects:
  # it scps `builds/autoqare-$BUILD_NUMBER.tar.gz`, where the version comes
  # from `RELEASE_VERSION=$BUILD_NUMBER` on the `mix release` call. On the
  # box, `bin/autoqare eval "Autoqare.Release.migrate()"` and then
  # `bin/autoqare daemon` (`Autoqare.Release` lists every command).
  defp releases do
    [
      autoqare: [
        # Explicit, and in dependency order: utils ← data ← core ← api_shared
        # ← api_* ← api, with notifire a sibling of core. Only `api_team`
        # depends on notifire (its dev routes), so naming it here is what
        # makes a release deliver mail whatever the routers need.
        # `runtime_tools` is what makes `bin/autoqare remote` and observer
        # usable against a live node.
        applications: [
          runtime_tools: :permanent,
          utils: :permanent,
          data: :permanent,
          core: :permanent,
          notifire: :permanent,
          # The routers the endpoint forwards to, below it.
          api_shared: :permanent,
          api_team: :permanent,
          api_client: :permanent,
          api_ext: :permanent,
          api: :permanent
        ],
        path: "builds",
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Available only to the umbrella root, not to the apps. Every other
  # third-party dependency lives in `apps/utils/mix.exs`.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # The same gates CI runs, in the same order, so a green local run means a
  # green pipeline. `mix precommit` is the only command anyone needs to learn.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      # `--quiet` on create, not on migrate: the migration stack is the one
      # moment you want to watch, because it is where a migration fails.
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate"] ++ seeds(),
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # An empty database with the production seed alone: what a deployment's
      # database looks like before anyone arrives.
      "ecto.reset.clean": ["ecto.drop", "ecto.create --quiet", "ecto.migrate", "aq.prod_seed"],
      # Just the data, on a database that already exists.
      "ecto.seed": seeds(),
      # `data` starts the Repo, so a test run needs the database to exist.
      # **`aq.seed_reference` belongs to preparing the database**, not to
      # seeding demo data: reference lists are closer to the schema than to
      # content, and a suite that depends on someone having run `ecto.reset`
      # by hand fails for the next person to clone.
      test: [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "aq.seed_reference",
        "test"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  # **The suite's database is empty because nothing seeds it**, not because a
  # seed checks where it is. Only the reference lists load under
  # `MIX_ENV=test`.
  #
  # Outside test, a dev database holds what a deployment holds (the production
  # seed, which starts with the reference groups and is idempotent) and then
  # the dev-only rows. Add a new seed task here, never to the aliases directly.
  #
  # `aq.seed_standard` is last: the standard test set (`Core.Standard`,
  # docs/TEST-ACCOUNTS.md), made through the front door, so it needs the
  # production seed first. It lives in `core` and does nothing outside dev.
  defp seeds do
    ["aq.seed_reference"] ++
      if Mix.env() == :test,
        do: [],
        else: ["aq.prod_seed", "aq.seed_demo", "aq.seed_standard"]
  end
end
