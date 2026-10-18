# SearXNG

Self-hosted privacy-respecting metasearch engine (`search.woitzik.dev`).

## Storage

None — stateless, aggregates results from upstream search engines on each query, no
local index or history to lose.

## Known limitation: most general-web engines are disabled

duckduckgo/brave/startpage/wikidata/qwant/mojeek/yahoo and `google` have all been
tried and are disabled: they CAPTCHA, return access-denied, or scrape their own
unrelated "related content" widgets as if they were real results. This is
search-engine bot detection keying on SearXNG's request fingerprint, not this
instance's IP -- see
[ADR-041](../../../docs/decisions/ADR-041-searxng-egress-fingerprint-blocking.md).

Two general-web engines are enabled:

- `bing` -- parses server-rendered results.
- `google cse` -- the Custom Search JSON API on a separate host
  (`cse.google.com`), not the JS-rendered `google.com/search` that `google` uses;
  see [ADR-060](../../../docs/decisions/ADR-060-searxng-google-cse-reenable.md).

The robust long-term fix remains SearXNG's official `braveapi` engine (a real API,
not scraped) -- needs a paid Brave Search API key, not wired up here.
