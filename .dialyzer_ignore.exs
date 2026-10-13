[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 once a catalogue holds a plural
  # message. Known upstream false positive, skipped the same way in the other
  # PhoenixKit modules.
  {"lib/phoenix_kit_legal/gettext.ex", :call_without_opaque}
]
