import Config

# This package ships no dev/prod config — it is a library, configured by
# the host app. `config/test.exs` exists solely to point the new
# integration-test Repo (test/support/legal_test_repo.ex) at a real
# PostgreSQL database; see AGENTS.md, "Testing".
if config_env() == :test do
  import_config "test.exs"
end
