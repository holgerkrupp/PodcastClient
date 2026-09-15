# Public Broadcaster Discovery

Discovery of podcasts produced by public-service broadcasters, offered on the
**Add Podcast** screen next to the existing Apple Podcasts category browser.

This is a **discovery layer only**. It finds shows and resolves an ordinary RSS
URL; from there the app's existing feed import takes over (`PodcastFeed` →
`PodcastBrowseView` → `SubscriptionManager.addToLibrary`).

Selecting a discovered show opens `PodcastBrowseView` **directly** — the same
screen an Apple-discovered podcast opens, with the same header, episode list and
Subscribe button. There is no discovery-specific detail screen.
`DiscoveredPodcastBrowseView` is only a resolver: providers that publish feeds
directly resolve on the first render and it is never seen, while the providers
that must look a feed up (ARD, RTP, SRG search results) show a progress view
first and a "Feed unavailable" state with the broadcaster's website on failure. A podcast subscribed
through SRF or RNZ is an entirely ordinary Up Next podcast afterwards — there is
no broadcaster-specific playback, storage or subscription behaviour anywhere.

Discovery results are never written to SwiftData. `DiscoveredPodcast` is a plain
value type; SwiftData objects are created only when the user actually subscribes.

## Layout

```
Raul/Features/Discovery/
    Models/      DiscoveredPodcast, PodcastDiscoveryCategory,
                 PublicBroadcaster, PodcastDiscoveryError
    Core/        PodcastDiscoveryProvider (protocol + capabilities)
                 PodcastDiscoveryRegistry, PublicBroadcasterCatalog
                 PodcastDiscoveryService (cross-provider search, feed resolution)
                 PodcastDiscoveryHTTPClient, PodcastDiscoveryCache
                 PodcastDiscoveryConfiguration
                 DiscoveryMarkupScanner, ApplePodcastsFeedResolver
    Providers/   SRGSSR/, ORF/, RNZ/, RTP/, ARD/
    Views/       PublicBroadcastersView, BroadcasterDiscoveryView,
                 PublicBroadcasterSearchView, DiscoveredPodcastBrowseView,
                 DiscoveredPodcastRowView
```

## Architecture

**`PodcastDiscoveryProvider`** is the only place that knows a broadcaster's API
or page structure. Everything above it works with `DiscoveredPodcast` values.

**Capabilities drive the UI.** A provider declares a
`PodcastDiscoveryCapabilities` option set (`featured`, `categories`,
`allPodcasts`, `search`, `feedURL`). The broadcaster screen renders exactly the
browse modes that come out of it — ARD, which can only search, shows a search
field and no empty tabs. The protocol's default implementations throw
`.unsupportedOperation`, so a provider implements only what its source offers.

**`PodcastDiscoveryRegistry`** pairs broadcasters with providers and is the
single source of truth for what is browsable. The UI never names a broadcaster;
`PublicBroadcastersView` iterates the registry and lists the browsable
broadcasters grouped by region. A catalog entry without a
provider is never shown as browsable.

**`PodcastDiscoveryService`** searches every searchable provider concurrently
with `withTaskGroup`. One provider failing contributes nothing and is otherwise
ignored. Results are ranked (exact title → prefix → substring → broadcaster-name
match) and de-duplicated by normalized feed URL, so the same show found through
two sources appears once.

**Failure isolation is the rule, not a nicety.** A provider that breaks affects
that broadcaster only: cross-provider search still returns everyone else's
results, and the Add Podcast screen never depends on discovery at all.

## Supported broadcasters

| Broadcaster | Country | Discovery source | RSS | Stability |
|-------------|---------|------------------|-----|-----------|
| SRF (SRG SSR) | CH | Official API (Integration Layer) | Yes, direct | High |
| RTS (SRG SSR) | CH | Official API + show page | Yes, one extra hop | High |
| ORF Sound | AT | Public audio API (`audioapi.orf.at`) | Yes, direct | High |
| RNZ | NZ | Public directory page | Yes, from the directory | Medium |
| RTP | PT | Public directory page | Via the Apple Podcasts link RTP publishes | Medium |
| ARD Sounds | DE | Undocumented web API | Best effort only | Low |
| CBC | CA | Public directory | Yes, direct | Medium |
| BBC | GB | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| NPR | US | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| Sveriges Radio | SE | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| RTÉ | IE | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| NPO | NL | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| ABC | AU | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| PBS | US | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| VRT | BE | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |
| ZDF | DE | Apple Podcasts catalogue, by publisher | Yes, direct | Medium |

Browse modes per provider:

| Broadcaster | Featured | Categories | A–Z | Search |
|-------------|----------|------------|-----|--------|
| SRF / RTS | – | Topics | Yes | Yes (API) |
| ORF Sound | – | Stations | Yes | Yes (local) |
| RNZ | – | – | Yes | Yes (local) |
| RTP | – | – | Yes | Yes (local) |
| ARD Sounds | – | Organizations | Yes | Yes (API) |
| CBC | – | Show category | Yes | Yes (local) |
| Apple-backed broadcasters | – | – | "Podcasts" selection | Yes (local) |

### SRG SSR (SRF, RTS) — official API

`https://il.srgssr.ch/integrationlayer/2.0/{bu}/…`

* `showList/radio/alphabetical` — the full radio catalogue, paged via `next`.
* `searchResultShowList?q=` — search. Results omit the feed, so
  `resolveFeed(for:)` makes one extra `show/radio/{id}` call.
* Categories are not a separate endpoint: each show lists its topics, so the
  cached catalogue is grouped locally instead of fetched twice.

**Not every SRG radio show is published as a podcast**, and how the feed is
reached differs per business unit (measured Sep 2026):

| Unit | Shows | Direct `podcastFeedSdUrl` | Show page advertising the feed |
|------|-------|---------------------------|-------------------------------|
| SRF  | 167   | 119                       | – |
| RTS  | 236   | 0                         | 119 (`podcastSubscriptionUrl`) |
| RSI  | 277   | 0                         | 0 |
| RTR  | 91    | 0                         | 0 |

So the catalogue is filtered to shows that are subscribable at all, and RTS feed
resolution takes one more hop: fetch `podcastSubscriptionUrl` and read the
`<link rel="alternate" type="application/rss+xml">` it advertises, reusing the
app's existing `PodcastFeedResolver.extractFeedURL(fromHTML:baseURL:)` rather
than adding a second implementation.

**RSI and RTR ship as planned entries, not providers.** SRG's API exposes no feed
for them by either route, so listing their shows would be a list of dead ends.

One provider instance per business unit; each is a separate broadcaster in the
catalog, both under Switzerland.

### ORF Sound — public API

`https://audioapi.orf.at/radiothek/api/2.0/podcasts` returns the entire
catalogue (~135 shows) in one document, grouped by station, each entry carrying
`urls.feed`. Browsing, categories (stations) and search all read the same cached
document. Shows flagged `isOnline: false` are skipped.

### RNZ — public directory

`https://www.rnz.co.nz/podcasts` embeds its series list as escaped JSON, each
series carrying its public RSS URL (`acast_url`). `RNZDirectoryParser` runs two
passes: the embedded series objects first, and — if that shape ever changes — a
fallback that pairs bare feed URLs with their slugs. Feed resolution can also
fall back to fetching the individual show page.

### RTP — public directory

`https://www.rtp.pt/play/podcasts` is server-rendered HTML; `RTPDirectoryParser`
reads the `<article id="program-id-…">` cards. RTP publishes no RSS URL, but it
does link each show to its Apple Podcasts entry, so `resolveFeed(for:)` opens the
show page, takes the Apple collection id and looks the feed up through the app's
existing Apple Podcasts client. That is an exact pointer, not a guess.

### ARD Sounds — undocumented web API

`https://api.ardaudiothek.de/search/programsets` is the API ARD's own clients
use. It is **not** a documented, stable developer API, so:

* all ARD networking lives behind `ARDSoundsDiscoveryProvider` / `ARDSoundsAPI`;
* ARD response types never leave the provider — they become `DiscoveredPodcast`
  immediately;
* failures are contained and never reach the rest of discovery;
* the provider can be switched off without a code change (see Configuration).

**Browsing** reads `/organizations`, which returns the whole catalogue in one
request — 14 organizations (BR, WDR, NDR, SWR, Deutschlandradio, funk, …), 84
stations and ~1400 shows (measured Sep 2026). Organizations become the
categories, so the axis is ARD's own. The catalogue response carries no
synopsis, so browsed shows have no description until the user searches for them.

ARD exposes no RSS feed of its own. `resolveFeed(for:)` therefore looks for the
conventional feed the originating ARD broadcaster publishes, via an **exact**
normalized title match on Apple Podcasts. The match is deliberately strict: a
generic title such as "Wissen" resolves to nothing rather than to the wrong
podcast, and the user is offered the broadcaster's website instead. Expect
roughly half of ARD shows to resolve.


### CBC — public directory

`https://www.cbc.ca/listen/cbc-podcasts` embeds one JSON object per show, each
carrying the show's own RSS URL, artwork, description and iTunes category, so
browsing, categories and search read one cached document (~147 shows, measured
Sep 2026) and no feed has to be looked up. `CBCDirectoryParser` anchors on the
feed URL and reads the remaining fields from a bounded window around it.

### BBC, NPR, Sveriges Radio, RTÉ, NPO, ABC, PBS, VRT, ZDF — Apple catalogue, by publisher

These broadcasters publish ordinary podcast feeds but expose no machine-readable
directory of their own: their sites render client-side, and the feed URLs are
simply not in the served markup. Sveriges Radio has an official programme API,
but its RSS endpoint answers 500 and its site refuses non-browser clients.

`ApplePublisherDiscoveryProvider` therefore finds their shows in the **Apple
Podcasts catalogue**, filtered to the broadcaster's own publisher names. Results
are real — each carries the broadcaster's own RSS feed, so subscribing behaves
exactly as everywhere else — but this is not the broadcaster's directory, and the
UI says so: every screen backed by it shows "Found in the Apple Podcasts
catalogue." The browse mode is called **Podcasts**, not "All Podcasts", because
Apple's result list is capped and relevance-ranked.

Publisher matching is explicit per broadcaster (`ApplePublisherRules`) rather
than a fuzzy name test, because publisher names collide: "ABC News" is both an
Australian and an American publisher, and Thai PBS, Iowa PBS and Cascade PBS are
unrelated to PBS. A prefix is used only where the stem is distinctive (BBC, RTÉ,
NPO, VRT); otherwise the publishers are listed exactly (NPR, Sveriges Radio, ABC,
PBS). Several narrow queries per broadcaster find more than one broad one.

Coverage measured Sep 2026, all with feeds: BBC 431, NPO 223, Sveriges Radio 140,
ABC 125, RTÉ 120, NPR 72, VRT 38, PBS 37, ZDF 13. These counts drift a little
between runs, because Apple ranks search results by relevance.

Germany therefore has two entries: **ARD Sounds** (the radio networks, via ARD's
own API) and **ZDF** (the television broadcaster, which publishes far fewer
podcasts). The ZDF rule deliberately excludes "funk – von ARD und ZDF", their
joint venture, because funk already appears inside ARD's catalogue.

Broadcasters left out of this provider on purpose: **Radio France** (58 publisher
matches, none with a feed URL), **RTVE** and **Yle** (no usable matches), and
**RAI** (too few, and its publisher names are not separable).

## Configuration and API keys

**No provider currently needs an API key.** The SRG SSR endpoints used here are
the public read endpoints and answer without a credential.

The plumbing exists for when that changes. `PodcastDiscoveryConfiguration` reads:

* **API keys** — `Info.plist` key `PodcastDiscovery<ProviderID>APIKey`
  (e.g. `PodcastDiscoverySrfAPIKey`), falling back to the process environment for
  local development. Add the provider id to
  `PodcastDiscoveryProviderKeys.providersRequiringAPIKeys` to have it read.
  Supply the value from an xcconfig or the CI environment — **never commit a key
  to source.** A provider without its key should report `.configurationMissing`,
  and the registry hides it.
* **Kill switch** — an array of provider ids under
  `PodcastDiscoveryDisabledProviders`, in `Info.plist` (ships with a build) or in
  `UserDefaults` (switch an integration off on a device without shipping). A
  disabled provider is removed from the registry, so it disappears from the
  broadcaster list and from cross-provider search.

## Caching

`PodcastDiscoveryCache` is an in-memory, TTL-based actor: catalogues for six
hours, searches for five minutes. Nothing is persisted in SwiftData — this is
remote catalogue data, not library content.

`PodcastDiscoveryHTTPClient` uses its own `URLSession` with a `URLCache` and
`.useProtocolCachePolicy`, so HTTP caching headers are respected as well.
Pull-to-refresh passes `refresh: true`, which bypasses both layers.

## Privacy

No account is required. Requests are plain GETs for public catalogue data and
carry nothing about the user's library, subscriptions or listening history.

## Known limitations

* **RNZ and RTP parse public HTML.** Both have fixture-backed tests and both
  fail softly, but a site redesign will need the parser updated. Neither uses
  brittle full-document regex for structure: RNZ reads the embedded JSON, RTP
  splits on article boundaries first so one card cannot borrow a neighbour's
  fields.
* **RTP's directory page lists only ~12 shows.** The rest of RTP's catalogue is
  loaded by client-side JavaScript that has no stable endpoint.
* **ARD feed resolution is best effort** (see above) and has no browse mode.
* **No broadcaster logos.** Obtaining logos reliably means hard-coding remote
  URLs that rot, so the list shows the country flag on a tinted tile instead. The
  country name is always spelled out next to it — the flag is never the only
  carrier of that information. `PublicBroadcaster.logoURL` is wired through and
  will be used if a reliable source appears.
* **The first cross-provider search is heavy.** RNZ, ORF and RTP have no search
  endpoint, so they search their own catalogue locally — which means the first
  query downloads those catalogues (RNZ's directory page is the large one at a
  few megabytes). Everything is cached for six hours afterwards, and each
  provider still runs concurrently with the rest.
* **SRG covers radio shows only** (`showList/radio`), and only those actually
  published as podcasts — see the table above.
* **Eight broadcasters are Apple-catalogue-backed, not broadcaster-backed** (see
  above). The selection is as complete as Apple's capped, relevance-ranked
  results allow, and those results carry no description, so rows show none —
  the podcast screen fills it in from the feed once opened.
* **Radio France, RTVE, Yle and RAI have no provider.** No directory, no feed
  URLs in their markup, and no usable publisher match in Apple's catalogue.
  Yle has an official API but it requires credentials. They stay planned.

## Adding another public broadcaster

1. Add a `PublicBroadcaster` to `PublicBroadcasterCatalog` (or move one out of
   `plannedBroadcasters`). Use a `LocalizedStringResource` for the summary so it
   reaches the string catalog.
2. Add a type conforming to `PodcastDiscoveryProvider` under
   `Providers/<Broadcaster>/`. Implement only the operations the source really
   supports and declare them in `capabilities` — the UI follows from that.
   Do all networking through `PodcastDiscoveryHTTPClient` and all caching
   through `PodcastDiscoveryCache`, and keep every API or HTML detail inside the
   provider's own files.
3. Register it in `PodcastDiscoveryRegistry.defaultProviders()`.
4. Add tests: decoding or parsing against a stored fixture, feed resolution
   (direct, resolved, and missing), and failure handling. Use `StubTransport`
   rather than contacting the broadcaster.

No view changes are needed at any point.

## Tests

* `PodcastDiscoveryRegistryTests` — registration, capabilities, broadcaster
  metadata, the kill switch, and that no key is baked into source.
* `PodcastDiscoveryParsingTests` — RNZ and RTP against stored HTML fixtures in
  `UpNextTests/Fixtures/`, including truncated and malformed markup.
* `PodcastDiscoverySearchTests` — concurrency, failure isolation,
  de-duplication and ranking.
* `PodcastDiscoveryProviderTests` — SRG, ORF, RNZ and ARD against
  `StubTransport`: decoding, catalogue building, caching, feed resolution, HTTP
  status and content-type handling, and that user-facing errors leak no
  technical detail.
