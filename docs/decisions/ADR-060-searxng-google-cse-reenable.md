# ADR-060: SearXNG's google cse engine is re-enabled, using a host separate from the blocked google engine

- **Status**: Accepted and applied.
- **Date**: 2026-10-18
- **Relates to**: ADR-041 (SearXNG egress fingerprint blocking), ADR-045 (engine
  timeout discarded results), `kubernetes/apps/searxng/searxng.yml`

## Context

ADR-041 disabled most of SearXNG's general-web engines after they began CAPTCHA'ing or
silently failing, concluding that the bot detection keys on SearXNG's outgoing request
fingerprint rather than on its source IP. `bing` was left enabled as the one engine
that still parses; `google` was left enabled but is unreliable (it JS-renders and
returns zero results for a meaningful fraction of queries).

`google cse` was disabled separately, in #872, for a different reason: timeouts. At the
`outgoing.request_timeout` in force at the time (2.0s, later 4.0s), its response landed
on or near the cap, and ADR-045 records that a timeout discards results the page
already holds -- so it rendered as zero hits. #880 then raised the cap to 8.0s, but the
engine was not re-enabled at that point.

`google cse` is not a scraped HTML engine. It fetches a token from
`https://www.google.com/cse/cse.js` and then queries the JSON endpoint
`https://cse.google.com/cse/element/v1`, returning structured results. That endpoint is
on a different host from `google.com/search`, which is blocked from this egress even
with a browser-like User-Agent:

```text
GET https://www.google.com/search?q=...        (Nokia/Symbian UA)  -> HTTP/1.1 403 Forbidden
GET https://www.google.com/wml/search?q=...    (Nokia/Symbian UA)  -> HTTP/1.1 403 Forbidden
GET https://www.google.com/cse/cse.js?cx=...                       -> 200, 9076 bytes
GET https://cse.google.com/cse/element/v1?...                      -> 200, 70096 bytes, 20 results
```

The 403 on `google.com/search` and `google.com/wml/search` confirms the `google` engine
stays blocked from this egress; the 200 and full result set from `cse.google.com`
confirms `google cse` is not.

## Decision

Re-enable `google cse` in `kubernetes/apps/searxng/searxng.yml` alongside `bing`, and
leave the scraped `google` engine disabled.

Verified end-to-end through the instance's own JSON API after deployment: a query with
`format=json` returns results attributed to both `bing` and `google cse`.

`yandex` was probed the same way and returned HTTP 200 with no parseable result
markers, so it remains disabled.

## Consequences

- Queries now aggregate two independent general-web engines instead of one, so a
  single engine's flakiness no longer empties the result page.
- `google cse` depends on `cse.google.com` and on the public CSE token endpoint
  remaining reachable and stable; both are outside this cluster's control and can
  regress without notice, as the `google` engine already did.
- The robust long-term fix is still SearXNG's official `braveapi` engine (a real
  API, not scraped), which needs a paid Brave Search API key and is not wired up here.
