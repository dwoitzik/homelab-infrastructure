# ADR-041: SearXNG general-web engines blocked by request-fingerprint detection

**Date:** 2026-09-06
**Status:** Accepted.

## Context

PRs #698, #701, and #711 each disabled another batch of SearXNG's general-web
engines after they started CAPTCHA'ing or silently failing: brave, startpage,
wikidata, bing (a distinct bug -- scraped its own low-confidence "related
content" widgets as organic results), yahoo, and finally duckduckgo/qwant/
mojeek. The owner's own browser, from the same public IP, uses these same
search engines with zero issues -- ruling out IP-level blocking or
reputation. What's actually happening: search engines' bot detection keys on
SearXNG's outgoing request itself (TLS ClientHello/JA3 fingerprint unlike a
real browser, no JavaScript execution, missing browser-typical headers like
`Sec-Fetch-*`/`sec-ch-ua`, no persistent session cookies across requests),
independent of source IP.

### Options ruled out

- **FlareSolverr sidecar.** SearXNG has no documented or code-level support
  for routing an engine through FlareSolverr -- a full-text search of the
  `searxng/searxng` repository for "flaresolverr" returns zero hits. A
  maintainer has stated publicly that real-browser/headless-Chrome solutions
  are deliberately not integrated: too resource-intensive for a project
  meant to run on modest self-hosted instances. Standing up a FlareSolverr
  deployment would be real infrastructure wired to a setting that doesn't
  exist.
- **curl-impersonate / TLS fingerprint spoofing.** Same conclusion --
  SearXNG's HTTP client is not swappable at the config level for this.
- **google `use_mobile_ui: true`.** Real, documented option, applied -- it
  measurably helps (the mobile endpoint isn't subject to the same
  rate-limiting as desktop) but does not make Google reliable; a meaningful
  fraction of queries still return zero results with no error.

## Decision

Every scraped general-web engine (brave, duckduckgo, startpage, wikidata,
bing, qwant, mojeek, yahoo) stays disabled. `google` (mobile UI) is the only
general-web engine left enabled, alongside `wikipedia` for infobox-style
facts. This is deliberately less coverage than a working self-hosted
instance would have, in exchange for not serving wrong/misleading results
(bing's related-content scraping) or a wall of CAPTCHA errors on every page.

## Reasons

A metasearch engine that silently returns wrong content, or CAPTCHAs on most
queries, is worse than one that's honest about limited coverage. None of the
scraping-based workarounds are real options for this project (see above);
shipping something that looks more complete but periodically lies about
result relevance is the wrong trade for a personal search tool.

## Trade-offs

Search quality is genuinely degraded versus a normal browser or a paid
search API -- this is not a full fix, it's the least-broken stable state
available for free. Google mobile UI still fails silently on some queries.

## Consequences

The real fix, if this instance's search quality needs to improve further,
is SearXNG's official `braveapi` engine -- a real Brave Search API
integration, not a scraped page, so immune to this whole fingerprinting
problem. It requires a Brave Search API key; the free tier ended February
2026, so this now needs a paid subscription decision, not a config change.
Not wired up here -- that's the owner's call, not something to activate
unilaterally. If accepted, add `- name: brave` with an `api_key` (via Vault/
ExternalSecret, not inline) rather than re-enabling the scraped `brave`
engine.

## Update (2026-09-09): the images category had the exact same problem, never checked

This ADR's investigation was scoped to general-web engines; nobody had
checked whether the same fingerprinting problem also hit the separate
`images` category engine list. It did. SearXNG's `/stats/errors` endpoint
(real, structured, machine-readable failure data, not a guess) showed
`brave.images` and `startpage images` at a sustained 100% failure rate
(rate-limit suspension and CAPTCHA redirect respectively) and `openverse`
at 100% timeout. `duckduckgo images` never appeared in any live search
response's per-engine timing breakdown despite being nominally enabled --
consistent with the same duckduckgo-family fingerprinting block already
established for the web engine, just not yet caught by the error-stats
snapshot. All four disabled, same treatment as the general engines above.
Image search still has 10 working engines left (bing images, google cse
images, pinterest, unsplash, flickr, wikicommons.images, pexels, artic,
plus the icon-set engines devicons/lucide), so this narrows rather than
guts image coverage.
