import Config

config :phoenix, :json_library, Jason

config :cymphony_elixir, CymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: CymphonyElixirWeb.ErrorHTML, json: CymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CymphonyElixir.PubSub,
  live_view: [signing_salt: "cymphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

# `CymphonyElixir.Application.start/2` installs both disk log sinks
# unconditionally, and their defaults are derived from
# `CymphonyConfig.config_dir/0` — the operator's real `~/.cymphony`. Without an
# override, every `mix test` run appends the whole suite's warning noise (raw
# agent stdout included) to the daemon log an operator tails, and rotates their
# real `daemon.log`. Redirect both sinks into the gitignored `tmp/` tree for the
# test run; `CymphonyElixir.LogFileTest` still exercises the real defaults by
# pointing `:config_dir_override` at a temporary directory.
if config_env() == :test do
  test_log_root = Path.expand("../tmp/test-logs", __DIR__)

  config :cymphony_elixir,
    log_file: Path.join([test_log_root, "log", "cymphony.log"]),
    daemon_log_file: Path.join(test_log_root, "daemon.log"),
    # Every test orchestrator would otherwise share one state file (the
    # operator's real one, absent an override) and restore each other's
    # retries. `DurableStateTest` and the restart tests turn it back on
    # against a temporary path.
    durable_orchestrator_state: false
end
