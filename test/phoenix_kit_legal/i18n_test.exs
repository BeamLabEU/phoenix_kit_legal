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
    original_backend = Gettext.get_locale(LegalGettext)
    original_global = Gettext.get_locale()

    on_exit(fn ->
      Gettext.put_locale(LegalGettext, original_backend)
      Gettext.put_locale(original_global)
    end)

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

    test "de locale translates the 'Legal' msgid" do
      assert translate("de", "Legal") == "Rechtliches"
    end

    test "fr locale translates the 'Legal' msgid" do
      assert translate("fr", "Legal") == "Mentions légales"
    end

    test "de locale translates page titles" do
      assert translate("de", "Privacy Policy") == "Datenschutzerklärung"
      assert translate("de", "Cookie Policy") == "Cookie-Richtlinie"
      assert translate("de", "Terms of Service") == "Nutzungsbedingungen"
    end

    test "fr locale translates page titles" do
      assert translate("fr", "Privacy Policy") == "Politique de confidentialité"
      assert translate("fr", "Cookie Policy") == "Politique relative aux cookies"
      assert translate("fr", "Terms of Service") == "Conditions d'utilisation"
    end

    test "de locale translates consent-widget banner strings" do
      assert translate("de", "We value your privacy") == "Uns ist Ihre Privatsphäre wichtig"
      assert translate("de", "Accept All") == "Alle akzeptieren"
      assert translate("de", "Reject") == "Ablehnen"
      assert translate("de", "Customize") == "Anpassen"
    end

    test "fr locale translates consent-widget banner strings" do
      assert translate("fr", "We value your privacy") ==
               "Nous accordons de l'importance à votre vie privée"

      assert translate("fr", "Accept All") == "Tout accepter"
      assert translate("fr", "Reject") == "Refuser"
      assert translate("fr", "Customize") == "Personnaliser"
    end

    # Unlike ru/et above, this pair cannot pin all four category names: `de`
    # and `fr` both render "Marketing" identically to the English msgid (spot
    # checked against priv/gettext/{de,fr}/LC_MESSAGES/default.po). Asserting
    # it here would pass even with a missing or corrupted de/fr catalogue,
    # since Gettext falls back to the msgid on a miss. Essential, Analytics,
    # and Preferences all differ from their msgids and are pinned instead —
    # Marketing is deliberately left uncovered by this test.
    test "de locale translates consent-widget category names" do
      assert translate("de", "Essential") == "Notwendig"
      assert translate("de", "Analytics") == "Analyse"
      assert translate("de", "Preferences") == "Präferenzen"
    end

    test "fr locale translates consent-widget category names" do
      assert translate("fr", "Essential") == "Essentiels"
      assert translate("fr", "Analytics") == "Analytique"
      assert translate("fr", "Preferences") == "Préférences"
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

    test "de locale resolves 'Legal' to 'Rechtliches'" do
      Gettext.put_locale(LegalGettext, "de")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Rechtliches"
    end

    test "fr locale resolves 'Legal' to 'Mentions légales'" do
      Gettext.put_locale(LegalGettext, "fr")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Mentions légales"
    end

    # Every other test here sets the locale on this module's backend. The
    # application does not: core sets it globally and, separately, on
    # `PhoenixKitWeb.Gettext` (`phoenix_kit/lib/phoenix_kit_web/users/auth.ex`
    # around the `put_locale` calls). The global locale does reach this backend
    # — but only while the backend has none of its own, and a backend-scoped
    # locale WINS over the global one:
    #
    #     put_locale(LegalGettext, "en"); put_locale("ru")
    #     #=> get_locale(LegalGettext) == "en", label == "Legal"
    #
    # So the backend-scoped tests force the strongest scope there is and always
    # get their translation, while the scope the application actually uses went
    # unexercised. Anything that leaves a locale on this backend in the same
    # process — a future `put_locale(LegalGettext, ...)` added here or upstream,
    # mirroring what core already does for its own backend — would leave the tab
    # English in a Russian UI with all eight translation tests still green.
    test "the locale the application sets — global, not backend-scoped — reaches the tab" do
      Gettext.put_locale("ru")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Юридические документы"
    end

    test "global locale reaches the tab for et as well" do
      Gettext.put_locale("et")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Õigusdokumendid"
    end

    test "global locale reaches the tab for de as well" do
      Gettext.put_locale("de")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Rechtliches"
    end

    test "global locale reaches the tab for fr as well" do
      Gettext.put_locale("fr")

      tab = Enum.find(Legal.settings_tabs(), &(&1.id == :admin_settings_legal))
      assert Tab.localized_label(tab) == "Mentions légales"
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
