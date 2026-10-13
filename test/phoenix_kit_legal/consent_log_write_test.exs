defmodule PhoenixKit.Modules.Legal.ConsentLogWriteTest do
  @moduledoc """
  The one thing the pure tests cannot show: that a decision reaches
  `phoenix_kit_consent_logs`.

  The rows go to a session-local shadow of the table (`CREATE TEMP TABLE`,
  which Postgres resolves before `public`), inside a transaction that is
  rolled back — so nothing is created in, or written to, any shared schema.
  Its `varchar` widths are read from `ConsentLog.column_widths/0`, like every
  other DDL in this package.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.Modules.Legal.Consent
  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Modules.Legal.Test.Repo

  @moduletag :integration

  @secret String.duplicate("s", 64)

  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :repo, previous),
        else: Application.delete_env(:phoenix_kit, :repo)
    end)

    for {key, value} <- [
          {"legal_consent_log_enabled", "true"},
          {"legal_consent_log_ip", "false"},
          {"legal_consent_log_user_agent", "false"},
          {"legal_consent_cookie_days", "180"}
        ],
        do: PhoenixKit.Cache.put(:settings, key, value)

    :ok
  end

  defp in_shadow_table(fun) do
    widths = ConsentLog.column_widths()

    Repo.transaction(fn ->
      Repo.query!("""
      CREATE TEMP TABLE phoenix_kit_consent_logs (
        uuid uuid PRIMARY KEY,
        user_uuid uuid,
        session_id varchar(#{widths.session_id}),
        consent_type varchar(#{widths.consent_type}) NOT NULL,
        consent_given boolean NOT NULL DEFAULT false,
        consent_version varchar(#{widths.consent_version}),
        ip_address varchar(#{widths.ip_address}),
        user_agent_hash varchar(#{widths.user_agent_hash}),
        metadata jsonb DEFAULT '{}',
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL
      ) ON COMMIT DROP
      """)

      fun.()
      Repo.rollback(:done)
    end)
  end

  defp request(headers \\ []) do
    conn = %{conn(:post, "/phoenix_kit/api/consent") | secret_key_base: @secret}

    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp rows, do: ConsentLog |> Repo.all() |> Enum.sort_by(& &1.consent_type)

  test "a decision is one row per category, keyed by the consent ID" do
    in_shadow_table(fn ->
      {:ok, _conn, recorded} =
        Consent.record(request(), %{"analytics" => true, "marketing" => false},
          version: "2026-10-13",
          source: "preferences"
        )

      assert [analytics, marketing, preferences] = rows()

      assert {analytics.consent_type, analytics.consent_given} == {"analytics", true}
      assert {marketing.consent_type, marketing.consent_given} == {"marketing", false}
      assert {preferences.consent_type, preferences.consent_given} == {"preferences", false}

      for row <- [analytics, marketing, preferences] do
        assert row.session_id == recorded.id
        assert row.consent_version == "2026-10-13"
        assert row.metadata == %{"source" => "preferences", "gpc" => false}
        assert row.user_uuid == nil
      end
    end)
  end

  test "keeps no address and no User-Agent unless the settings ask" do
    headers = [{"user-agent", "Mozilla/5.0 Test"}, {"sec-gpc", "1"}]

    in_shadow_table(fn ->
      {:ok, _conn, _recorded} = Consent.record(request(headers), %{}, version: "1.0")

      assert [%{ip_address: nil, user_agent_hash: nil, metadata: %{"gpc" => true}} | _] = rows()
    end)

    PhoenixKit.Cache.put(:settings, "legal_consent_log_ip", "true")
    PhoenixKit.Cache.put(:settings, "legal_consent_log_user_agent", "true")

    in_shadow_table(fn ->
      {:ok, _conn, _recorded} = Consent.record(request(headers), %{}, version: "1.0")

      assert [%{ip_address: "127.0.0.1", user_agent_hash: hash} | _] = rows()
      assert hash == ConsentLog.hash_user_agent("Mozilla/5.0 Test")
    end)
  end

  test "records the signed-in user when there is one" do
    user_uuid = UUIDv7.generate()

    in_shadow_table(fn ->
      {:ok, _conn, _recorded} =
        Consent.record(request(), %{}, version: "1.0", user_uuid: user_uuid)

      assert Enum.all?(rows(), &(&1.user_uuid == user_uuid))
    end)
  end

  test "the same decision again is not logged twice, a changed one is" do
    in_shadow_table(fn ->
      {:ok, _conn, first} = Consent.record(request(), %{"analytics" => true}, version: "1.0")
      again = request([{"cookie", "pk_consent=#{Consent.encode(first, @secret)}"}])

      {:ok, _conn, _same} = Consent.record(again, %{"analytics" => true}, version: "1.0")
      assert length(rows()) == 3

      {:ok, _conn, _changed} = Consent.record(again, %{"analytics" => false}, version: "1.0")
      assert length(rows()) == 6
    end)
  end

  test "forgetting logs every category as refused" do
    in_shadow_table(fn ->
      {:ok, _conn, first} = Consent.record(request(), %{"analytics" => true}, version: "1.0")

      request([{"cookie", "pk_consent=#{Consent.encode(first, @secret)}"}])
      |> Consent.forget(source: "preferences")

      assert [granted, withdrawn] = Enum.filter(rows(), &(&1.consent_type == "analytics"))
      assert Enum.sort([granted.consent_given, withdrawn.consent_given]) == [false, true]
    end)
  end

  test "forgetting a decision that granted nothing writes nothing" do
    in_shadow_table(fn ->
      {:ok, _conn, first} = Consent.record(request(), %{}, version: "1.0")
      request([{"cookie", "pk_consent=#{Consent.encode(first, @secret)}"}]) |> Consent.forget()

      assert length(rows()) == 3
    end)
  end

  test "nothing is written while the log is switched off" do
    PhoenixKit.Cache.put(:settings, "legal_consent_log_enabled", "false")

    in_shadow_table(fn ->
      {:ok, conn, _recorded} = Consent.record(request(), %{"analytics" => true}, version: "1.0")

      assert rows() == []
      assert Map.has_key?(conn.resp_cookies, "pk_consent")
    end)
  end

  test "a decision made signed out is logged once more, with the user, after sign-in" do
    user_uuid = UUIDv7.generate()

    in_shadow_table(fn ->
      {:ok, _conn, anonymous} = Consent.record(request(), %{"analytics" => true}, version: "1.0")
      cookie = fn consent -> [{"cookie", "pk_consent=#{Consent.encode(consent, @secret)}"}] end

      assert Enum.map(rows(), & &1.user_uuid) == [nil, nil, nil]

      {:ok, _conn, attributed} =
        Consent.record(request(cookie.(anonymous)), %{"analytics" => true},
          version: "1.0",
          user_uuid: user_uuid
        )

      # Three more rows: the same decision, under the same consent ID, now
      # naming who made it.
      assert length(rows()) == 6
      named = Enum.filter(rows(), &(&1.user_uuid == user_uuid))
      assert length(named) == 3
      assert Enum.all?(named, &(&1.session_id == anonymous.id))

      # Once: the re-issued cookie says it is done.
      for opts <- [[user_uuid: user_uuid], []] do
        {:ok, _conn, _same} =
          Consent.record(
            request(cookie.(attributed)),
            %{"analytics" => true},
            [version: "1.0"] ++ opts
          )
      end

      assert length(rows()) == 6
    end)
  end

  test "a rejected entry is logged by field and message, never with what it holds" do
    PhoenixKit.Cache.put(:settings, "legal_consent_log_ip", "true")
    user_uuid = UUIDv7.generate()

    # A version longer than its column: every entry is rejected by the
    # changeset, before any table is touched.
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Consent.record(request(), %{"analytics" => true},
          version: String.duplicate("9", 40),
          user_uuid: user_uuid
        )
      end)

    # The visitor's choice is honoured all the same.
    assert {:ok, conn, _recorded} = result
    assert Map.has_key?(conn.resp_cookies, "pk_consent")

    assert log =~ "consent decision was not logged: consent_version should be at most"

    for held <- ["127.0.0.1", user_uuid, "Ecto.Changeset", "ip_address", "999999"],
        do: refute(log =~ held)
  end
end
