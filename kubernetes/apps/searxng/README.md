# SearXNG

Self-hosted privacy-respecting metasearch engine (`search.woitzik.dev`).

## Storage

None — stateless, aggregates results from upstream search engines on each query, no
local index or history to lose.

## Known limitation: most general-web engines are disabled

Google, wikipedia, and duckduckgo/brave/startpage/wikidata/bing/qwant/mojeek/yahoo have
all been tried; only `google` (mobile UI) and `wikipedia` are currently enabled. The
rest CAPTCHA, return access-denied, or (bing) scrape their own unrelated
"related content" widgets as if they were real results. This is search-engine
bot detection keying on SearXNG's request fingerprint, not this instance's IP --
see [ADR-041](../../../docs/decisions/ADR-041-searxng-egress-fingerprint-blocking.md)
for what was investigated and why. `google` (mobile UI) is the sole general-web engine
enabled and is itself unreliable (silently returns zero results for some queries).
The real fix is SearXNG's official `braveapi` engine (a real API, not scraped) --
needs a paid Brave Search API key, not wired up here.
