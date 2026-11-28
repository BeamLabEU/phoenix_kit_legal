# PR #26 review

Reviewed the page-store adapter, template resolution, translated templates, consent reporting, dependencies and database fixture changes against the repository's main branch.

| Severity | Finding | Resolution |
| --- | --- | --- |
| BUG - HIGH | A failed language lookup or a fallback post from the store could direct a translation write into the primary-language page. | Generation propagates the lookup error and verifies the returned post's language before updating it. |
| BUG - MEDIUM | An English fallback page could render data-collection declarations in the requested language. Repeated template lookups could also fingerprint different bytes from those evaluated. | Generation uses one resolved template and builds the declarations, title and language assign in its locale. The fingerprint comes from the evaluated bytes. |
| BUG - MEDIUM | Retrying an undelivered decision after switching languages attributed it to the retry page. Withdrawal omitted the document language entirely. | New decisions retain their original locale through retries. The withdrawal request includes the document language. |
| BUG - MEDIUM | Two template generations could read the same settings map and overwrite one another's entries. | The read and update share a PostgreSQL transaction with a transaction-scoped advisory lock, including when the setting has yet to be created. |
| BUG - MEDIUM | A regional tag with different casing or separators could miss a generated translation. The audit metadata also left the origin of each fingerprint ambiguous. | Lookup normalizes stored and requested tags. Each policy fingerprint identifies its source as generated or resolved. The module declares its newly logged data in all five catalogues. |

A generated fingerprint identifies the template used during generation. Publishing can edit, publish or trash the resulting post independently. Neither a generated fingerprint nor one resolved at decision time establishes which published revision a visitor opened.
