import Config

# Read when the release boots, so one build serves every environment; the
# environment is the only difference. Only what a server must decide is a
# variable: sample.env lists them. Required ones raise at boot, naming the
# variable.

# Google sign-in. Unset: no real Google, and in dev the stand-in stays on.
if google_client_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :core, :google, client_id: google_client_id
end

# Where the mails' links open, when the apps are not on localhost.
if console_url = System.get_env("CONSOLE_URL") do
  portal_url = System.get_env("PORTAL_URL", console_url)
  config :core, :app_urls, console: console_url, portal: portal_url
  config :notifire, :app_urls, console: console_url, portal: portal_url
end

# The backend's own origin, for the emails' one-click unsubscribe
# (AQ-10B §11.4): `List-Unsubscribe: <API_URL/unsubscribe?token=…>`.
if api_url = System.get_env("API_URL") do
  config :notifire, api_url: api_url
end

if notifications_email = System.get_env("MAILER_NOTIFICATIONS_EMAIL") do
  config :notifire, notifications_email: notifications_email
end

# Web Push (AQ-08 §7.6): a server with a VAPID pair sends push; one without
# sends none, and the screens say "Push isn't set up on this server."
if vapid_private = System.get_env("VAPID_PRIVATE_KEY") do
  config :notifire, :web_push,
    public_key: System.fetch_env!("VAPID_PUBLIC_KEY"),
    private_key: vapid_private,
    subject: System.get_env("VAPID_SUBJECT", "mailto:support@autoqare.com")
end

# Forwarded mail (AQ-09 §6, §11.4): the address with `{token}` (Postmark's
# own `<hash>+{token}@inbound.postmarkapp.com` until P13's domain), and the
# webhook's basic-auth pair. Without a password the webhook answers 503.
if inbound_address = System.get_env("INBOUND_ADDRESS") do
  unless String.contains?(inbound_address, "{token}"),
    do: raise("INBOUND_ADDRESS must hold {token}, e.g. in+{token}@in.autoqare.com")

  config :core, :inbound, address: inbound_address
end

if inbound_password = System.get_env("INBOUND_PASSWORD") do
  config :core, :inbound,
    user: System.get_env("INBOUND_USER", "postmark"),
    password: inbound_password
end

if config_env() == :prod do
  # Every rule below is `Autoqare.RuntimeEnv`'s, a pure function of this map
  # with its own test; a missing or unknown value raises at boot, naming the
  # variable (DEPLOY-PLAN §6). `bin/autoqare eval` boots this too, so a
  # migration needs the same `.env` sourced as the server.
  alias Autoqare.RuntimeEnv

  env = System.get_env()

  # Never the stand-in in a release.
  config :core, :google, stand_in: false

  # D-5: `DATABASE_URL` when set, else tCart's pieces `AQ_DB_HOST · NAME ·
  # USER · PWD · PORT`, which Jenkins' reset job fills with the prefix `AQ`.
  config :data,
         Data.Repo,
         RuntimeEnv.database(env) ++
           [
             show_sensitive_data_on_connection_error: false,
             # Several apps share each box's Postgres.
             pool_size: RuntimeEnv.integer!(env, "POOL_SIZE", 10)
           ]

  # The apps that may call the API — and open its socket. An allowlist, never `*`.
  cors_origins =
    env
    |> RuntimeEnv.required!("CORS_ORIGINS", """
    The apps' origins, comma-separated — the team console and the customer portal:

        CORS_ORIGINS=https://team.autoqare.com,https://autoqare.com
    """)
    |> RuntimeEnv.list()

  config :api, cors_origins: cors_origins

  config :api, Api.Endpoint,
    # A release serves nothing without it.
    server: true,
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      # Must match proxy_pass in this host's nginx site (README.autoqare.md):
      # 4901 dev and prod, 4902 staging, 4911 the office's dev1.
      port: RuntimeEnv.integer!(env, "PORT", 4100)
    ],
    check_origin: cors_origins,
    secret_key_base:
      RuntimeEnv.secret!(
        env,
        "SECRET_KEY_BASE",
        "Signs Phoenix's tokens. Generate: mix phx.gen.secret"
      )

  # config.exs ships a dev secret; a release must never sign with it.
  config :core, Core.Auth.Guardian,
    secret_key:
      RuntimeEnv.secret!(
        env,
        "GUARDIAN_SECRET_KEY",
        "Signs auth tokens. MUST differ from SECRET_KEY_BASE. Generate: mix phx.gen.secret"
      )

  # Uploaded bytes live on persistent storage outside the release directory.
  config :core, :storage,
    root:
      RuntimeEnv.required!(
        env,
        "UPLOADS_ROOT",
        "A directory on persistent storage, outside the release directory, owned by the user this runs as."
      )

  # Where every email and invitation link opens (§6: both required in a
  # release, or the links would point at localhost).
  console_url =
    RuntimeEnv.required!(env, "CONSOLE_URL", "The team console, e.g. https://team.autoqare.com.")

  portal_url =
    RuntimeEnv.required!(env, "PORTAL_URL", "The customer portal, e.g. https://autoqare.com.")

  config :core, :app_urls, console: console_url, portal: portal_url
  config :notifire, :app_urls, console: console_url, portal: portal_url

  # D-4, L2: Amazon SES on the servers, or `local`, Swoosh's in-memory
  # mailbox, where nothing leaves the box. prod.exs turns that mailbox's
  # storage off for `ses`; `local` needs it running, or every delivery fails.
  mailer = RuntimeEnv.mailer(env)
  config :notifire, Notifire.Mailer, mailer
  config :swoosh, local: mailer[:adapter] == Swoosh.Adapters.Local

  config :notifire,
    from_email:
      RuntimeEnv.required!(
        env,
        "MAILER_FROM_EMAIL",
        "e.g. hello@autoqare.com — an address or domain the mail provider has verified."
      )

  # D-9: remote dev's standard test accounts sign in with `password123`,
  # which the worst-list refuses. `AQ_ALLOW_TEST_PASSWORDS=true` sets what a
  # dev server sets (dev.exs) and lets `Autoqare.Release.seed_standard/0`
  # run. Staging and production never set it.
  if RuntimeEnv.allow_test_passwords?(env) do
    config :core, dev_worst_passwords: true
  end

  log_level = Map.get(env, "LOG_LEVEL", "info")

  if log_level not in ~w(emergency alert critical error warning notice info debug) do
    raise "LOG_LEVEL=#{inspect(log_level)} is not a Logger level."
  end

  config :logger, level: String.to_existing_atom(log_level)
end
