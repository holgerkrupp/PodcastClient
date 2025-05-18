#  Podcast Features to implement


✅ Podlove Namespace

Namespace URL: http://podlove.org/simple-chapters

Primarily used by the Podlove Podcast Publisher, with structured metadata and modular formats.

Notable Tags (under podlove:):
- [x] <psc:chapters> — Inline chapter list.
- [x] <psc:chapter start="00:01:23.000" title="Intro" href="..." image="..." />
- [ ] Podlove Alternate Feeds

- [ ] Podlove Paged Feeds
- [ ] Podlove Deep Linking


✅ Podcasting 2.0 Namespace

Namespace URL: https://podcastindex.org/namespace/1.0

An open standard to expand podcasting with decentralized, modern features.

Notable Tags:
- [ ] <podcast:person> — Credit people (roles: host, guest, voice, etc.).
- [ ] <podcast:location> — Geolocation of episode/show.
- [x] <podcast:transcript> — Link to a transcript file (WebVTT, SRT, etc.).
- - [x] WebVTT
- - [ ] SRT
- - [ ] JSON
- [ ] <podcast:chapters> — Link to chapter file (e.g. JSON format).
- [ ] <podcast:funding> — Monetization URL with description (e.g. Patreon).
- [ ] <podcast:medium> — Show type (e.g. audio, video, music).
- [ ] <podcast:guid> — Global unique identifier (permanent).
- [ ] <podcast:license> — Licensing info (e.g. Creative Commons).
- [ ] <podcast:trailer> — Points to trailer episodes.
- [ ] <podcast:liveItem> — Defines live stream events.
- [ ] <podcast:remoteItem> — Reference another feed/episode.
- [ ] <podcast:social> — Links to social media profiles.
- [ ] <podcast:value> — Streaming payments support (e.g. Lightning Network).
- [ ] <podcast:txt> — Verifies feed ownership via DNS.
More evolving tags available at: https://podcastnamespace.org


✅ iTunes / Apple Podcast Namespace

Namespace URL: http://www.itunes.com/dtds/podcast-1.0.dtd

Apple popularized podcasting by extending RSS with custom tags. These are widely supported.

Key Tags:
- [x] <itunes:author> — Show/episode author.
- [ ] <itunes:subtitle> — Short description.
- [ ] <itunes:summary> — Full episode/show description.
- [ ] <itunes:explicit> — yes/no/clean for explicit content.
- [x] <itunes:image href="..." /> — Show or episode artwork.
- [ ] <itunes:category> — Nested categories (e.g. Arts > Design).
- [ ] <itunes:episode> — Episode number.
- [ ] <itunes:season> — Season number.
- [ ] <itunes:title> — Custom title separate from - [ ] <title>.
- [ ] <itunes:episodeType> — full, trailer, or bonus.
- [ ] <itunes:block> — Prevent listing (yes).
