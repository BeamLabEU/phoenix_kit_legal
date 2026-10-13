defmodule PhoenixKit.Modules.Legal.Test.SettingsRecorder do
  @moduledoc """
  Stands in for `PhoenixKit.Settings` as the writer behind
  `PhoenixKit.Modules.Legal.put_setting/4` (`config :phoenix_kit_legal,
  :settings_writer`).

  This suite has no database behind the settings, so a real write raises
  before it can show anything. This module writes nothing: it tells the
  calling process what would have been written — the key, the value and the
  options that carry who made the change — as a `{:setting_written, …}`
  message. Not a repository, and no stand-in for one: what a write does to
  the database is still only verifiable against a real one.
  """

  @doc "Routes this process's settings writes here until the test ends."
  def install do
    Application.put_env(:phoenix_kit_legal, :settings_writer, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:phoenix_kit_legal, :settings_writer)
    end)

    :ok
  end

  @doc "Every write reported to this process so far, oldest first."
  def written do
    receive do
      {:setting_written, write} -> [write | written()]
    after
      0 -> []
    end
  end

  def update_setting_with_module(key, value, module, opts),
    do: record(:string, key, value, module, opts)

  def update_boolean_setting_with_module(key, value, module, opts),
    do: record(:boolean, key, value, module, opts)

  def update_json_setting_with_module(key, value, module, opts),
    do: record(:json, key, value, module, opts)

  defp record(kind, key, value, module, opts) do
    write = %{kind: kind, key: key, value: value, module: module, opts: opts}
    send(self(), {:setting_written, write})
    {:ok, write}
  end
end
