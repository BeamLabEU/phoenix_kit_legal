defmodule PhoenixKit.Modules.Legal.I18nTest do
  @moduledoc """
  Coverage for the per-module Gettext wiring.

  Tests are split into two describe blocks:

    * "module's own catalogue" — exercises the
      `PhoenixKit.Modules.Legal.Gettext` backend directly
      (page titles, consent-widget strings). Runs against
      every `phoenix_kit` release because it never touches
      `Tab.localized_label/1` or the `gettext_backend:`
      field.

    * "settings_tabs/0 wiring" — exercises
      `Tab.localized_label/1` and the `gettext_backend:` /
      `gettext_domain:` fields on `%Tab{}`, both introduced
      by [BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522).
      Tagged `:requires_phoenix_kit_i18n_api` so
      `test_helper.exs` can exclude it on releases that
      pre-date the API.
  """

  use ExUnit.Case, async: false

  # `Tab.localized_label/1` ships with phoenix_kit#522. Suppress the
  # undefined-function warning until that API is in a Hex release —
  # the call sites are gated behind `:requires_phoenix_kit_i18n_api`
  # in `test_helper.exs` and only run when the function is exported.
  @compile {:no_warn_undefined, [{PhoenixKit.Dashboard.Tab, :localized_label, 1}]}

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Gettext, as: LegalGettext

  setup do
    original = Gettext.get_locale(LegalGettext)
    on_exit(fn -> Gettext.put_locale(LegalGettext, original) end)
    :ok
  end

  describe "module's own catalogue" do
    test "ru locale translates the 'Legal' msgid" do
      assert translate("ru", "Legal") == "Юридические документы"
    end

    test "et locale translates the 'Legal' msgid" do
      assert translate("et", "Legal") == "Õigusdokumendid"
    end

    test "ru locale translates page titles" do
      assert translate("ru", "Privacy Policy") == "Политика конфиденциальности"
      assert translate("ru", "Cookie Policy") == "Политика использования cookie"
      assert translate("ru", "Terms of Service") == "Условия использования"
    end

    test "et locale translates page titles" do
      assert translate("et", "Privacy Policy") == "Privaatsuspoliitika"
      assert translate("et", "Cookie Policy") == "Küpsiste poliitika"
      assert translate("et", "Terms of Service") == "Kasutustingimused"
    end

    test "ru locale translates consent-widget banner strings" do
      assert translate("ru", "We value your privacy") == "Мы ценим вашу конфиденциальность"
      assert translate("ru", "Accept All") == "Принять все"
      assert translate("ru", "Reject") == "Отклонить"
      assert translate("ru", "Customize") == "Настроить"
    end

    test "ru locale translates consent-widget category names" do
      assert translate("ru", "Essential") == "Необходимые"
      assert translate("ru", "Analytics") == "Аналитика"
      assert translate("ru", "Marketing") == "Маркетинг"
      assert translate("ru", "Preferences") == "Предпочтения"
    end

    test "et locale translates consent-widget banner strings" do
      assert translate("et", "We value your privacy") == "Hindame sinu privaatsust"
      assert translate("et", "Accept All") == "Nõustu kõigega"
      assert translate("et", "Reject") == "Keeldu"
      assert translate("et", "Customize") == "Kohanda"
    end

    test "et locale translates consent-widget category names" do
      assert translate("et", "Essential") == "Vajalikud"
      assert translate("et", "Analytics") == "Analüütika"
      assert translate("et", "Marketing") == "Turundus"
      assert translate("et", "Preferences") == "Eelistused"
    end

    test "unknown locale falls back to the msgid" do
      assert translate("zz", "Legal") == "Legal"
      assert translate("zz", "Privacy Policy") == "Privacy Policy"
    end
  end

  describe "settings_tabs/0 wiring" do
    # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
    # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
    # Once the consumer's `phoenix_kit` dep resolves to a release that ships
    # `Tab.localized_label/1`, the helper detects it and these tests run
    # automatically — no follow-up edit needed.
    @describetag :requires_phoenix_kit_i18n_api

    test "every tab carries the module's own gettext backend" do
      tabs = Legal.settings_tabs()

      # `for` over an empty list asserts nothing. Reproduced by emptying
      # `settings_tabs/0`: the three locale tests below reddened (their
      # `Enum.find/2` returns nil) and this one stayed green, reporting that
      # every tab was wired correctly because there were no tabs.
      #
      # Anchored on the tab this module is known to register rather than on a
      # count, so adding a second tab does not need a number changed here — and
      # so a rename of the existing one is a failure rather than a silent skip.
      assert Enum.any?(tabs, &(&1.id == :admin_settings_legal)),
             "settings_tabs/0 no longer registers :admin_settings_legal " <>
               "(got #{inspect(Enum.map(tabs, & &1.id))}) — every assertion below " <>
               "iterates that list and passes trivially when it is empty"

      for tab <- tabs do
        assert tab.gettext_backend == LegalGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end

    test "ru locale resolves 'Legal' to 'Юридические документы'" do
      Gettext.put_locale(LegalGettext, "ru")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Юридические документы"
    end

    test "et locale resolves 'Legal' to 'Õigusdokumendid'" do
      Gettext.put_locale(LegalGettext, "et")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Õigusdokumendid"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(LegalGettext, "zz")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == tab.label
    end
  end

  defp translate(locale, msgid) do
    Gettext.with_locale(LegalGettext, locale, fn ->
      Gettext.gettext(LegalGettext, msgid)
    end)
  end
end
