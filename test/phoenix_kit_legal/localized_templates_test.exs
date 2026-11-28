defmodule PhoenixKit.Modules.Legal.LocalizedTemplatesTest do
  @moduledoc """
  Bundled templates exist in English, Estonian and Russian; any other
  language falls back to English, and the resolved locale says so.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal.TemplateGenerator

  @templates ~w(acceptable_use ccpa_notice cookie_policy data_retention_policy do_not_sell
                privacy_policy terms_of_service)

  @context %{
    company_name: "Acme OÜ",
    company_address: "Narva mnt 5, Tallinn",
    company_country: "Estonia",
    company_website: "https://acme.example",
    registration_number: "12345678",
    vat_number: "EE123",
    dpo_name: "Mari",
    dpo_email: "dpo@acme.example",
    dpo_phone: "",
    dpo_address: "",
    frameworks: ["gdpr", "ccpa"],
    effective_date: "2026-11-26"
  }

  describe "a host's own templates win over the bundled ones" do
    defp host(files),
      do: fn name -> if name in files, do: {:ok, "/host/" <> name}, else: :error end

    test "a host's English override beats a bundled translation it has none for" do
      assert {"/host/privacy_policy.eex", "en"} =
               TemplateGenerator.resolve("privacy_policy.eex", "et", host(["privacy_policy.eex"]))
    end

    test "a host's own translation beats its English and the bundled one" do
      files = ["privacy_policy.eex", "privacy_policy.et.eex"]

      assert {"/host/privacy_policy.et.eex", "et"} =
               TemplateGenerator.resolve("privacy_policy.eex", "et-EE", host(files))
    end

    test "without host overrides the bundled translation is used" do
      assert {path, "et"} = TemplateGenerator.resolve("privacy_policy.eex", "et", host([]))
      assert String.ends_with?(path, "privacy_policy.et.eex")
      refute String.starts_with?(path, "/host/")
    end

    test "regional host templates are found across case and separators" do
      for language <- ["ET_ee", "et-ee", "et-EE"] do
        assert {"/host/privacy_policy.et-EE.eex", "et-EE"} =
                 TemplateGenerator.resolve(
                   "privacy_policy.eex",
                   language,
                   host(["privacy_policy.et-EE.eex"])
                 )
      end
    end

    test "English asks the host first" do
      assert {"/host/privacy_policy.eex", "en"} =
               TemplateGenerator.resolve("privacy_policy.eex", "en", host(["privacy_policy.eex"]))

      assert {path, "en"} = TemplateGenerator.resolve("privacy_policy.eex", "en", host([]))
      assert String.ends_with?(path, "privacy_policy.eex")
    end
  end

  test "an upper-case language subtag resolves to the lower-case catalogue" do
    assert {_path, "et"} = TemplateGenerator.resolve("privacy_policy.eex", "ET")
    assert {_path, "et"} = TemplateGenerator.resolve("privacy_policy.eex", "ET-ee")
    assert {_path, "ru"} = TemplateGenerator.resolve("privacy_policy.eex", "RU_ru")
  end

  test "every bundled template has an et and a ru version" do
    dir = Path.join(:code.priv_dir(:phoenix_kit_legal), "legal_templates")

    for name <- @templates, locale <- ~w(et ru) do
      assert File.exists?(Path.join(dir, "#{name}.#{locale}.eex")),
             "missing #{name}.#{locale}.eex"
    end
  end

  test "each translation keeps the source's EEx tags (only reader-facing literals differ)" do
    dir = Path.join(:code.priv_dir(:phoenix_kit_legal), "legal_templates")
    mask = fn tags -> Enum.map(tags, &Regex.replace(~r/"[^"]*"/, &1, ~s(""))) end
    tags = fn path -> Regex.scan(~r/<%.*?%>/s, File.read!(path)) |> List.flatten() |> mask.() end

    for name <- @templates, locale <- ~w(et ru) do
      assert tags.(Path.join(dir, "#{name}.eex")) ==
               tags.(Path.join(dir, "#{name}.#{locale}.eex")),
             "#{name}.#{locale}.eex has different EEx tags from #{name}.eex"
    end
  end

  test "et, ru and their regional forms resolve to their own templates" do
    assert {_, "et"} = TemplateGenerator.resolve("privacy_policy.eex", "et")
    assert {_, "et"} = TemplateGenerator.resolve("privacy_policy.eex", "et-EE")
    assert {_, "ru"} = TemplateGenerator.resolve("privacy_policy.eex", "ru_RU")
    assert {path, "ru"} = TemplateGenerator.resolve("privacy_policy.eex", "ru")
    assert String.ends_with?(path, "privacy_policy.ru.eex")
  end

  test "English and every other language fall back to the English base template" do
    for language <- ["en", "en-US", "de", "fr", nil, "../../etc/passwd", ""] do
      assert {path, "en"} = TemplateGenerator.resolve("privacy_policy.eex", language)
      assert String.ends_with?(path, "privacy_policy.eex")
    end
  end

  @tag :tmp_dir
  test "a host template receives the resolved language and fingerprints the evaluated bytes", %{
    tmp_dir: dir
  } do
    source = "Language: <%= @language %>"
    path = Path.join(dir, "custom.eex")
    File.write!(path, source)
    expected = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    assert {:ok, "Language: en", "sha256:" <> ^expected} =
             TemplateGenerator.render_resolved({path, "en"}, %{})
  end

  test "template_version/2 fingerprints the resolved file" do
    en = TemplateGenerator.template_version("privacy_policy.eex", "en")
    et = TemplateGenerator.template_version("privacy_policy.eex", "et")

    assert en =~ ~r/^sha256:[0-9a-f]{12}$/
    assert et =~ ~r/^sha256:[0-9a-f]{12}$/
    refute en == et
    assert TemplateGenerator.template_version("privacy_policy.eex", "de") == en
  end

  test "every translated template renders" do
    for name <- @templates, locale <- ~w(et ru) do
      assert {:ok, content} = TemplateGenerator.render("#{name}.eex", @context, locale)
      assert content =~ "Acme OÜ", "#{name}.#{locale} does not render the company"
    end
  end

  test "an Estonian render is in Estonian" do
    {:ok, content} = TemplateGenerator.render("privacy_policy.eex", @context, "et")
    {:ok, english} = TemplateGenerator.render("privacy_policy.eex", @context, "en")
    refute content == english
    assert content =~ "isikuandme"
  end
end
