# PR #26 follow-up

The merge includes the fixes in [the review](CODEX_REVIEW.md). Regression coverage exercises failed and fallback translation lookups, the successful generation record, resolved language and fingerprint, regional tag matching, decision retries, and withdrawal reporting.

A Chromium smoke test used a local host fixture with no server-rendered consent component. The package injected its widget and sent the document language on the rejection POST and withdrawal DELETE.

The complete ExUnit suite passed with 406 tests, including the PostgreSQL integration tests. All 20 JavaScript tests passed.
