import Config

# Compile-time production defaults; everything a server decides is in
# runtime.exs, so one build serves every environment.

# Raise per host with LOG_LEVEL (runtime.exs), no rebuild.
config :logger, level: :info

# No in-memory mailbox in a release by default: mail goes through the
# provider `MAILER_ADAPTER` names (runtime.exs, D-4). `MAILER_ADAPTER=local`
# turns the mailbox's storage back on there, since that adapter needs it.
config :swoosh, local: false
