#  Podcast Features to implement

I'm trying to integrate the addtions to the podcast definition created by the Podlove project as well as the 'Podcasting 2.0 Namepace'. Here is a small tracker about my progress.

✅ Podlove Namespace

Namespace URL: http://podlove.org/simple-chapters

Primarily used by the Podlove, with structured metadata and modular formats.

Notable Tags (under podlove:):
- [x] <psc:chapters> — Inline chapter list.
- [x] <psc:chapter start="00:01:23.000" title="Intro" href="..." image="..." />
- [ ] Podlove Alternate Feeds

- [x] Podlove Paged Feeds
- [x] Podlove Deep Linking


✅ Podcasting 2.0 Namespace

Namespace URL: https://podcastindex.org/namespace/1.0

An open standard to expand podcasting with decentralized, modern features.

Notable Tags:
- [x] <podcast:person> — Credit people (roles: host, guest, voice, etc.).
- [ ] <podcast:location> — Geolocation of episode/show.
- [x] <podcast:transcript> — Link to a transcript file (WebVTT, SRT, etc.).
- - [x] WebVTT
- - [x] SRT
- - [x] JSON
- [x] <podcast:chapters> — Link to chapter file (e.g. JSON format).
- [x] <podcast:funding> — Monetization URL with description (e.g. Patreon).
- [ ] <podcast:medium> — Show type (e.g. audio, video, music).
- [x] <podcast:guid> — Global unique identifier (permanent).
- [ ] <podcast:license> — Licensing info (e.g. Creative Commons).
- [ ] <podcast:trailer> — Points to trailer episodes.
- [ ] <podcast:liveItem> — Defines live stream events.
- [ ] <podcast:remoteItem> — Reference another feed/episode.
- [x] <podcast:social> — Links to social media profiles.
- [ ] <podcast:value> — Streaming payments support (e.g. Lightning Network).
- [ ] <podcast:txt> — Verifies feed ownership via DNS.
More evolving tags available at: https://podcastnamespace.org


✅ iTunes / Apple Podcast Namespace

Namespace URL: http://www.itunes.com/dtds/podcast-1.0.dtd

Apple popularized podcasting by extending RSS with custom tags. These are widely supported.

Key Tags:
- [x] <itunes:author> — Show/episode author.
- [x] <itunes:subtitle> — Short description.
- [x] <itunes:summary> — Full episode/show description.
- [ ] <itunes:explicit> — yes/no/clean for explicit content.
- [x] <itunes:image href="..." /> — Show or episode artwork.
- [ ] <itunes:category> — Nested categories (e.g. Arts > Design).
- [x] <itunes:episode> — Episode number.
- [ ] <itunes:season> — Season number.
- [x] <itunes:title> — Custom title separate from - [ ] <title>.
- [ ] <itunes:episodeType> — full, trailer, or bonus.
- [ ] <itunes:block> — Prevent listing (yes).
