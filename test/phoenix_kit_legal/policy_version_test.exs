defmodule PhoenixKit.Modules.Legal.PolicyVersionTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Modules.Publishing.DBStorage.Mapper
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  @moduledoc """
  The policy version is a value with a long fuse: `get_auto_policy_version/0`
  feeds `get_consent_widget_config/0`, the widget hands it back on every consent
  decision, and it lands in `phoenix_kit_consent_logs.consent_version` — core's
  `varchar(20)`. A wrong value here is not a display bug; it is either an
  audit-trail outage or a re-consent prompt that never fires.

  These tests pin the two ends of that chain: the key Publishing actually
  publishes the page timestamp under, and the width guard at the producer.
  """

  describe "auto policy version reads the key Publishing actually emits" do
    # `list_generated_pages/0` read `metadata.updated_at` for the page timestamp.
    # Publishing has never had that key — the timestamp is `:content_updated_at`
    # at the TOP level of the post map — so the field was permanently nil and
    # `get_auto_policy_version/0` permanently returned the manual setting.
    # Effect: updating a privacy policy never bumped the consent version, so no
    # visitor was ever re-prompted to consent, which is the entire point of
    # versioning it.
    #
    # Asserted against Publishing's own mapper rather than a hand-written map, so
    # a rename in Publishing fails here instead of silently reinstating the bug.
    setup do
      updated_at = ~N[2026-08-10 22:03:27.123456]

      post = %PublishingPost{
        uuid: "00000000-0000-0000-0000-0000000000p1",
        slug: "privacy-policy",
        mode: "slug",
        active_version_uuid: "00000000-0000-0000-0000-0000000000v1"
      }

      version = %PublishingVersion{
        uuid: "00000000-0000-0000-0000-0000000000v1",
        version_number: 1,
        status: "published",
        data: %{}
      }

      content = %PublishingContent{
        uuid: "00000000-0000-0000-0000-0000000000c1",
        language: "en",
        title: "Privacy Policy",
        content: "body",
        url_slug: "privacy-policy",
        data: %{},
        updated_at: updated_at
      }

      %{
        post_map: Mapper.to_post_map(post, version, content, [content], [version]),
        updated_at: updated_at
      }
    end

    test "the timestamp is at :content_updated_at, not under :metadata", ctx do
      assert ctx.post_map[:content_updated_at] == ctx.updated_at,
             """
             Publishing no longer exposes the page timestamp as \
             :content_updated_at.

             `PhoenixKit.Modules.Legal.list_generated_pages/0` reads that key to
             build `updated_at`, which `get_auto_policy_version/0` turns into the
             consent version. Follow the rename there, or the auto version goes
             back to being permanently nil.
             """

      refute Map.has_key?(ctx.post_map.metadata, :updated_at),
             """
             Publishing's :metadata now carries :updated_at after all. That is the
             key `list_generated_pages/0` used to read exclusively, and reading it
             alone is what made the auto policy version dead; the fallback in
             `list_generated_pages/0` covers it either way, but check which of the
             two is authoritative before trusting this one.
             """
    end
  end

  describe "producers respect core's width in Postgres' unit" do
    # Postgres counts varchar(n) in characters — code points. `String.length/1`
    # and `validate_length/3`'s default count graphemes. They agree on ASCII and
    # part ways on exactly the input a human types into a version field and never
    # tests: a combining mark, or an emoji ZWJ sequence.
    @twenty_graphemes_forty_codepoints String.duplicate("é", 20)

    test "update_policy_version/1 counts code points, not graphemes" do
      assert 20 == String.length(@twenty_graphemes_forty_codepoints)
      assert 40 == length(String.codepoints(@twenty_graphemes_forty_codepoints))

      assert {:error, :version_too_long} =
               Legal.update_policy_version(@twenty_graphemes_forty_codepoints)
    end

    test "the changeset counts code points, not graphemes" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: "s",
          consent_version: @twenty_graphemes_forty_codepoints
        })

      refute changeset.valid?,
             """
             consent_version passed the length validation at 40 code points into a \
             varchar(20).

             Postgres rejects it, and `ConsentLog.create/1` is public API — the
             caller gets the raw Postgrex overflow these validations exist to
             replace. `validate_column_widths/1` needs `count: :codepoints`.
             """

      assert {"should be at most %{count} character(s)", _} = changeset.errors[:consent_version]
    end
  end
end
