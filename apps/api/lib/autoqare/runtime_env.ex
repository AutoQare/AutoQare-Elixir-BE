defmodule Autoqare.RuntimeEnv do
  @moduledoc """
  What a release's environment means, as config (DEPLOY-PLAN §6, D-5, D-9).

  `config/runtime.exs` reads `System.get_env()` once and hands the map to
  these functions, so every rule a server's `.env` must satisfy is a pure
  function with a test (`runtime_env.test.exs`) rather than a branch that
  only runs on a deploy day. Each one answers config or **raises with words
  naming the variable**, so a release that is missing something refuses to
  boot and says what to add. `sample.env` lists every variable.

  It sits in `api`, beside `Autoqare.Release`, because it speaks for every
  app's config (`data`'s Repo, `notifire`'s mailer, `core`'s password rule)
  and `api` is the app on top of them all. It names no module of theirs:
  the mailer adapters are atoms in config, as they would be in a `.exs`.

  The shapes are tCart's (`config/runtime.exs` there): the DB pieces, the
  `MAILER_ADAPTER` choice, the required-variable message.
  """

  @type env :: %{optional(String.t()) => String.t()}

  @db_pieces [
    {"AQ_DB_HOST", :hostname, "Where Postgres listens, e.g. 127.0.0.1."},
    {"AQ_DB_NAME", :database, "e.g. autoqare_dev, autoqare_staging, autoqare_prod."},
    {"AQ_DB_USER", :username, "The Postgres role this app connects as."},
    {"AQ_DB_PWD", :password, "The password for AQ_DB_USER."}
  ]

  @doc """
  A variable that must be set and non-empty, or a raise naming it with `hint`.
  """
  @spec required!(env(), String.t(), String.t()) :: String.t()
  def required!(env, name, hint) do
    case env[name] do
      value when is_binary(value) and value != "" -> value
      _missing -> raise missing(name, hint)
    end
  end

  @doc """
  A secret: required, and at least 64 bytes (Phoenix's key base wants it,
  and Guardian signs with HS512).
  """
  @spec secret!(env(), String.t(), String.t()) :: String.t()
  def secret!(env, name, hint) do
    value = required!(env, name, hint)

    if byte_size(value) < 64 do
      raise """

      Environment variable #{name} is too short (#{byte_size(value)} bytes, needs >= 64).

      Generate one with:  mix phx.gen.secret
      """
    end

    value
  end

  @doc "An integer, `default` when unset or empty; anything else raises."
  @spec integer!(env(), String.t(), integer()) :: integer()
  def integer!(env, name, default) do
    case env[name] do
      blank when blank in [nil, ""] ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _invalid -> raise "Environment variable #{name} must be an integer, got: #{value}"
        end
    end
  end

  @doc """
  `Data.Repo`'s connection (D-5): **`DATABASE_URL` wins when set**;
  otherwise the pieces `AQ_DB_HOST`, `AQ_DB_NAME`, `AQ_DB_USER`, `AQ_DB_PWD`
  and `AQ_DB_PORT` (default 5432), tCart's shape, which Jenkins' reset job
  fills with the prefix `AQ`. Neither complete raises, naming what is missing.

      iex> Autoqare.RuntimeEnv.database(%{"DATABASE_URL" => "ecto://u:p@db/x"})
      [url: "ecto://u:p@db/x"]
  """
  @spec database(env()) :: keyword()
  def database(env) do
    case env["DATABASE_URL"] do
      url when is_binary(url) and url != "" -> [url: url]
      _unset -> pieces(env)
    end
  end

  defp pieces(env) do
    case Enum.reject(@db_pieces, fn {name, _key, _hint} -> present?(env, name) end) do
      [] ->
        Enum.map(@db_pieces, fn {name, key, _hint} -> {key, env[name]} end) ++
          [port: integer!(env, "AQ_DB_PORT", 5432)]

      missing ->
        raise """

        The database is not configured: set DATABASE_URL, or all four of
        AQ_DB_HOST, AQ_DB_NAME, AQ_DB_USER and AQ_DB_PWD (AQ_DB_PORT is 5432
        unless set).

        Missing: #{Enum.map_join(missing, ", ", &elem(&1, 0))}.
        #{Enum.map_join(missing, "\n", fn {name, _key, hint} -> "  #{name}: #{hint}" end)}

        See sample.env in the repository root for the full list.
        """
    end
  end

  @doc """
  `Notifire.Mailer`'s adapter (D-4), from `MAILER_ADAPTER`, which a release
  must set:

    * `ses` — Amazon SES, with `AWS_SES_REGION`, `AWS_ACCESS_KEY_ID` and
      `AWS_SECRET_ACCESS_KEY` (each required);
    * `local` — Swoosh's in-memory mailbox: nothing leaves the box.

  Any other value raises.

      iex> Autoqare.RuntimeEnv.mailer(%{"MAILER_ADAPTER" => "local"})
      [adapter: Swoosh.Adapters.Local]
  """
  @spec mailer(env()) :: keyword()
  def mailer(env) do
    case required!(env, "MAILER_ADAPTER", "ses (the servers) or local (nothing leaves the box).") do
      "ses" ->
        [
          adapter: Swoosh.Adapters.AmazonSES,
          region:
            required!(env, "AWS_SES_REGION", "e.g. eu-west-1, where the sender is verified."),
          access_key: required!(env, "AWS_ACCESS_KEY_ID", "An IAM key allowed ses:SendRawEmail."),
          secret: required!(env, "AWS_SECRET_ACCESS_KEY", "That key's secret.")
        ]

      "local" ->
        [adapter: Swoosh.Adapters.Local]

      other ->
        raise """

        MAILER_ADAPTER=#{inspect(other)} is not recognised: ses or local.
        """
    end
  end

  @doc """
  D-9's switch, `AQ_ALLOW_TEST_PASSWORDS`: `true` lets this release accept
  the standard test password, which the worst-list refuses (it sets what a
  dev server sets, `config :core, dev_worst_passwords: true`), and lets
  `Autoqare.Release.seed_standard/0` run. Remote dev turns it on; staging and
  production never set it. Unset, empty or `false` is off; anything else
  raises rather than guessing.

      iex> Autoqare.RuntimeEnv.allow_test_passwords?(%{})
      false
      iex> Autoqare.RuntimeEnv.allow_test_passwords?(%{"AQ_ALLOW_TEST_PASSWORDS" => "true"})
      true
  """
  @spec allow_test_passwords?(env()) :: boolean()
  def allow_test_passwords?(env) do
    case env["AQ_ALLOW_TEST_PASSWORDS"] do
      "true" ->
        true

      off when off in [nil, "", "false"] ->
        false

      other ->
        raise """

        AQ_ALLOW_TEST_PASSWORDS=#{inspect(other)} is not recognised: true, or leave it unset.
        Only remote dev sets it (DEPLOY-PLAN D-9); production never does.
        """
    end
  end

  @doc "A comma-separated list, trimmed, with no empty items."
  @spec list(String.t()) :: [String.t()]
  def list(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp present?(env, name), do: is_binary(env[name]) and env[name] != ""

  defp missing(name, hint) do
    """

    Environment variable #{name} is missing (or empty).

    #{hint}

    See sample.env in the repository root for the full list.
    """
  end
end
