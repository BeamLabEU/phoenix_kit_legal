require Logger

# i18n tests require phoenix_kit with the `gettext_backend` API
# (see BeamLabEU/phoenix_kit#522). Until that ships in a Hex release,
# CI building against the published phoenix_kit lacks
# `PhoenixKit.Dashboard.Tab.localized_label/1` and the assertions
# would raise `UndefinedFunctionError`. Detect availability and
# exclude those tests when the API is missing — they run automatically
# the moment the consumer's `phoenix_kit` dep resolves to a release
# that includes the API.
i18n_excludes =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
        "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships the gettext_backend API."
    )

    [:requires_phoenix_kit_i18n_api]
  end

# `:integration` tests exercise `Migrations.up/1`'s adoption-shape check
# (test/phoenix_kit_legal/migrations/adoption_integration_test.exs)
# against a real PostgreSQL database — that check reads live catalog
# state (information_schema.columns, pg_indexes, pg_constraint) which no
# pure-function test can stand in for. Excluded automatically when no
# database is reachable, the same way the i18n gate above degrades
# rather than fails — see AGENTS.md, "Testing".
repo_config = Application.get_env(:phoenix_kit_legal, PhoenixKit.Modules.Legal.Test.Repo, [])

# Refuses outright, before anything attempts a connection, unless this is
# this package's own disposable database — see DatabaseGuard's moduledoc.
PhoenixKit.Modules.Legal.Test.DatabaseGuard.validate!(Keyword.fetch!(repo_config, :database))

# The probe is a single Postgrex connection with `backoff_type: :stop`
# (no retry) rather than starting the pooled Test.Repo directly: a pool's
# `start_link/0` returns `{:ok, _}` immediately regardless of whether the
# database is reachable — the actual connect happens lazily, with
# backoff, and a bad host/credential otherwise surfaces minutes later as
# a pool checkout timeout that reads like a flaky test rather than what
# it is. One classified attempt with the Repo's own connection options,
# checked synchronously, avoids that.
conn_opts =
  repo_config
  |> Keyword.take([:hostname, :port, :username, :password, :database])
  |> Keyword.merge(backoff_type: :stop, timeout: 5_000)

# `Postgrex.start_link/1` LINKS the connection to the calling process. A
# FATAL Postgres error (e.g. 28P01 invalid_password) is not something
# `backoff_type: :stop` merely declines to retry — the connection's own
# supervisor exceeds its restart intensity over the handful of attempts
# that happen before the caller can even react, and terminates
# non-normally. Unlinked (or with exits untrapped), that EXIT signal
# reaches this process — the one running `mix test`'s boot sequence,
# before ExUnit has even started — and kills it outright, which is
# exactly the crash-instead-of-gracefully-excluding failure mode this
# probe exists to avoid. Trapping exits for the duration of the probe
# turns that signal into an ordinary message this process can drain
# instead of dying to.
previous_trap_exit = Process.flag(:trap_exit, true)

db_reachable? =
  case Postgrex.start_link(conn_opts) do
    {:ok, pid} ->
      result =
        try do
          Postgrex.query(pid, "SELECT 1", [], timeout: 5_000)
        catch
          :exit, _reason -> :error
        end

      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      match?({:ok, _}, result)

    {:error, _reason} ->
      false
  end

drain_exits = fn drain_exits ->
  receive do
    {:EXIT, _pid, _reason} -> drain_exits.(drain_exits)
  after
    0 -> :ok
  end
end

drain_exits.(drain_exits)
Process.flag(:trap_exit, previous_trap_exit)

integration_excludes =
  if db_reachable? do
    {:ok, _pid} = PhoenixKit.Modules.Legal.Test.Repo.start_link()
    []
  else
    db = Keyword.get(conn_opts, :database)
    host = Keyword.get(conn_opts, :hostname)

    # IO.puts, not Logger — config/test.exs sets the logger level to
    # :warning (below :info), which would otherwise silently swallow this
    # message: a developer would see :integration tests excluded with no
    # indication why.
    IO.puts(:stderr, """
    [test_helper] Cannot reach #{inspect(db)} on #{inspect(host)} — :integration \
    tests excluded. First-time setup: createdb #{db} (against the right \
    PGHOST/PGUSER/PGPASSWORD — see config/test.exs). Run `mix test` again once \
    it is reachable.
    """)

    [:integration]
  end

ExUnit.start(exclude: i18n_excludes ++ integration_excludes)

# Start the PhoenixKit settings cache so Settings-backed helpers (e.g.
# Legal.hide_for_authenticated?/0) resolve cleanly without a full Ecto/Repo
# setup. Tests seed specific values via
# `PhoenixKit.Cache.put(:settings, key, value)`.
case PhoenixKit.Cache.Registry.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

case PhoenixKit.Cache.start_link(name: :settings) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
