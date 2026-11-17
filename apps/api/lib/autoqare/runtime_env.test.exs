defmodule Autoqare.RuntimeEnvTest do
  @moduledoc """
  A release's `.env` as config (DEPLOY-PLAN §6, D-4, D-5, D-9): each rule
  `config/runtime.exs` applies, as a pure function of an env map.
  """

  use ExUnit.Case, async: true

  alias Autoqare.RuntimeEnv

  doctest RuntimeEnv

  @pieces %{
    "AQ_DB_HOST" => "127.0.0.1",
    "AQ_DB_NAME" => "autoqare_dev",
    "AQ_DB_USER" => "autoqare",
    "AQ_DB_PWD" => "not-a-real-one"
  }

  describe "database/1 (D-5)" do
    test "the pieces, with the port 5432 unless set" do
      assert RuntimeEnv.database(@pieces) == [
               hostname: "127.0.0.1",
               database: "autoqare_dev",
               username: "autoqare",
               password: "not-a-real-one",
               port: 5432
             ]

      assert RuntimeEnv.database(Map.put(@pieces, "AQ_DB_PORT", "5517"))[:port] == 5517
    end

    test "DATABASE_URL wins when set, whatever the pieces say" do
      env = Map.put(@pieces, "DATABASE_URL", "ecto://u:p@db:5432/autoqare_prod")
      assert RuntimeEnv.database(env) == [url: "ecto://u:p@db:5432/autoqare_prod"]
    end

    test "an empty DATABASE_URL falls back to the pieces" do
      assert RuntimeEnv.database(Map.put(@pieces, "DATABASE_URL", ""))[:hostname] == "127.0.0.1"
    end

    test "neither complete raises, naming both ways and what is missing" do
      error =
        assert_raise RuntimeError, fn -> RuntimeEnv.database(Map.delete(@pieces, "AQ_DB_PWD")) end

      assert error.message =~ "set DATABASE_URL, or all four"
      assert error.message =~ "Missing: AQ_DB_PWD."

      error = assert_raise RuntimeError, fn -> RuntimeEnv.database(%{}) end
      assert error.message =~ "Missing: AQ_DB_HOST, AQ_DB_NAME, AQ_DB_USER, AQ_DB_PWD."
    end

    test "a port that is not a number raises" do
      assert_raise RuntimeError, ~r/AQ_DB_PORT must be an integer/, fn ->
        RuntimeEnv.database(Map.put(@pieces, "AQ_DB_PORT", "54x"))
      end
    end
  end

  describe "mailer/1 (D-4)" do
    @ses %{
      "MAILER_ADAPTER" => "ses",
      "AWS_SES_REGION" => "eu-west-1",
      "AWS_ACCESS_KEY_ID" => "CHANGE_ME",
      "AWS_SECRET_ACCESS_KEY" => "CHANGE_ME"
    }

    test "ses is Amazon SES with its region and key" do
      assert RuntimeEnv.mailer(@ses) == [
               adapter: Swoosh.Adapters.AmazonSES,
               region: "eu-west-1",
               access_key: "CHANGE_ME",
               secret: "CHANGE_ME"
             ]
    end

    test "ses without one of its variables raises, naming it" do
      for name <- ~w(AWS_SES_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY) do
        error = assert_raise RuntimeError, fn -> RuntimeEnv.mailer(Map.delete(@ses, name)) end
        assert error.message =~ "Environment variable #{name} is missing"
      end
    end

    test "local keeps the mail on the box" do
      assert RuntimeEnv.mailer(%{"MAILER_ADAPTER" => "local"}) == [adapter: Swoosh.Adapters.Local]
    end

    test "it is required, and an unknown adapter raises" do
      assert_raise RuntimeError, ~r/MAILER_ADAPTER is missing/, fn -> RuntimeEnv.mailer(%{}) end

      assert_raise RuntimeError, ~r/"postmark" is not recognised: ses or local/, fn ->
        RuntimeEnv.mailer(%{"MAILER_ADAPTER" => "postmark"})
      end
    end
  end

  describe "allow_test_passwords?/1 (D-9)" do
    test "only true turns it on; unset, empty and false are off" do
      assert RuntimeEnv.allow_test_passwords?(%{"AQ_ALLOW_TEST_PASSWORDS" => "true"})
      refute RuntimeEnv.allow_test_passwords?(%{})
      refute RuntimeEnv.allow_test_passwords?(%{"AQ_ALLOW_TEST_PASSWORDS" => ""})
      refute RuntimeEnv.allow_test_passwords?(%{"AQ_ALLOW_TEST_PASSWORDS" => "false"})
    end

    test "anything else raises rather than guessing" do
      assert_raise RuntimeError, ~r/"yes" is not recognised/, fn ->
        RuntimeEnv.allow_test_passwords?(%{"AQ_ALLOW_TEST_PASSWORDS" => "yes"})
      end
    end
  end

  describe "the required-variable helpers" do
    test "required!/3 raises on missing or empty, naming the variable and the hint" do
      assert RuntimeEnv.required!(%{"X" => "1"}, "X", "hint") == "1"

      for env <- [%{}, %{"X" => ""}] do
        error =
          assert_raise RuntimeError, fn -> RuntimeEnv.required!(env, "X", "Set X to one.") end

        assert error.message =~ "Environment variable X is missing (or empty)."
        assert error.message =~ "Set X to one."
        assert error.message =~ "sample.env"
      end
    end

    test "secret!/3 wants 64 bytes" do
      long = String.duplicate("a", 64)
      assert RuntimeEnv.secret!(%{"S" => long}, "S", "hint") == long

      assert_raise RuntimeError, ~r/S is too short \(63 bytes/, fn ->
        RuntimeEnv.secret!(%{"S" => String.duplicate("a", 63)}, "S", "hint")
      end
    end

    test "integer!/3 defaults when unset and refuses a non-number" do
      assert RuntimeEnv.integer!(%{}, "PORT", 4100) == 4100
      assert RuntimeEnv.integer!(%{"PORT" => ""}, "PORT", 4100) == 4100
      assert RuntimeEnv.integer!(%{"PORT" => "4901"}, "PORT", 4100) == 4901

      assert_raise RuntimeError, ~r/PORT must be an integer/, fn ->
        RuntimeEnv.integer!(%{"PORT" => "49 01"}, "PORT", 1)
      end
    end

    test "list/1 splits on commas and trims" do
      assert RuntimeEnv.list(" https://a.test , https://b.test,,") == [
               "https://a.test",
               "https://b.test"
             ]
    end
  end
end

defmodule Autoqare.RuntimeEnv.RuntimeExsTest do
  @moduledoc """
  `config/runtime.exs` itself, read as a release reads it (`env: :prod`)
  from a throwaway environment. Not async: it sets the process's
  environment variables for one read and puts them back.
  """

  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)

  @env %{
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "GUARDIAN_SECRET_KEY" => String.duplicate("g", 64),
    "AQ_DB_HOST" => "127.0.0.1",
    "AQ_DB_NAME" => "autoqare_dev",
    "AQ_DB_USER" => "autoqare",
    "AQ_DB_PWD" => "CHANGE_ME",
    "PORT" => "4901",
    "CORS_ORIGINS" => "https://dev.team.autoqare.com, https://dev.autoqare.com",
    "CONSOLE_URL" => "https://dev.team.autoqare.com",
    "PORTAL_URL" => "https://dev.autoqare.com",
    "UPLOADS_ROOT" => "/tmp/autoqare-uploads",
    "MAILER_ADAPTER" => "ses",
    "AWS_SES_REGION" => "eu-west-1",
    "AWS_ACCESS_KEY_ID" => "CHANGE_ME",
    "AWS_SECRET_ACCESS_KEY" => "CHANGE_ME",
    "MAILER_FROM_EMAIL" => "hello@autoqare.com"
  }

  test "a complete remote-dev environment becomes the release's config" do
    config = read(Map.put(@env, "AQ_ALLOW_TEST_PASSWORDS", "true"))

    repo = config[:data][Data.Repo]
    assert repo[:hostname] == "127.0.0.1"
    assert repo[:database] == "autoqare_dev"
    assert repo[:port] == 5432
    refute Keyword.has_key?(repo, :url)

    assert config[:api][Api.Endpoint][:http][:port] == 4901

    assert config[:api][:cors_origins] == [
             "https://dev.team.autoqare.com",
             "https://dev.autoqare.com"
           ]

    assert config[:notifire][Notifire.Mailer][:adapter] == Swoosh.Adapters.AmazonSES
    assert config[:notifire][:from_email] == "hello@autoqare.com"

    assert config[:notifire][:app_urls] == [
             console: "https://dev.team.autoqare.com",
             portal: "https://dev.autoqare.com"
           ]

    assert config[:swoosh][:local] == false
    assert config[:core][:dev_worst_passwords] == true
  end

  test "production leaves the worst-list whole, and local mail keeps its mailbox running" do
    config = read(Map.put(@env, "MAILER_ADAPTER", "local"))

    refute Keyword.has_key?(config[:core], :dev_worst_passwords)
    assert config[:notifire][Notifire.Mailer] == [adapter: Swoosh.Adapters.Local]
    assert config[:swoosh][:local] == true
  end

  test "DATABASE_URL still works, and wins" do
    config = read(Map.put(@env, "DATABASE_URL", "ecto://u:CHANGE_ME@db:5432/autoqare_prod"))
    assert config[:data][Data.Repo][:url] == "ecto://u:CHANGE_ME@db:5432/autoqare_prod"
  end

  test "a missing required variable refuses to boot, naming it" do
    for name <- ~w(MAILER_ADAPTER CONSOLE_URL MAILER_FROM_EMAIL CORS_ORIGINS) do
      error = assert_raise RuntimeError, fn -> read(Map.delete(@env, name)) end
      assert error.message =~ name
    end
  end

  # Every variable runtime.exs reads, set to `env` for one read and put back.
  defp read(env) do
    names =
      Map.keys(@env) ++
        ~w(DATABASE_URL AQ_DB_PORT POOL_SIZE AQ_ALLOW_TEST_PASSWORDS LOG_LEVEL GOOGLE_CLIENT_ID API_URL
           MAILER_NOTIFICATIONS_EMAIL VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY INBOUND_ADDRESS INBOUND_PASSWORD)

    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    System.put_env(env)

    try do
      Config.Reader.read!(@runtime, env: :prod, target: :host)
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
