# Up Next

## Open Source Podcast Client

I started developing an open source podcast client in 2023 with the goal of building something that doesn’t rely on a central server. By 2024 I had a working alpha that already included features like transcripts, accidental skip detection, and other improvements I felt were missing from existing podcast apps.

This isn’t my first attempt at building a podcast app — I actually released my first client, **One Trick Pony**, about nine years ago. Life took me in other directions for a while, but now I’m back at it—this time starting almost from scratch. I’m targeting iOS 26, adopting Swift 6, and following its strict concurrency rules to avoid race conditions. Some parts of the old codebase will be reused, but the foundation is fresh.

The goal of this project is simple: **give back to the community.** I’ve enjoyed countless free podcasts over the last 20 years, and I also use free tools like Podlove Publisher and Ultraschall to publish my own. This app is my way of helping preserve podcasting as an open, independent medium—resisting efforts by companies to lock it down.

Key principles of the project:

* Built on the community-driven podcast catalog [fyyd](https://fyyd.de/)
* Independent of proprietary servers (all refreshes run locally on-device)
* 100% open source and free to use
* No locked features or restrictions
* No app-side ads (ads inserted by podcast publishers are outside the app's control)

## What makes Up Next different?

- **Search what was said — in every podcast.** Full-text search across **all locally stored episode transcripts** in your library, or restrict the search to **one podcast**. Find matching passages and jump back into the audio. Unlike a search limited to episode titles, descriptions, or the one transcript currently open, this searches the words actually spoken.
- **Create missing transcripts on your device.** Transcribe episodes with Apple's on-device speech recognition, manually or automatically after downloads. Publisher-provided transcripts are used when available; no Up Next transcription server is required.
- **Generate chapters from transcripts.** Use on-device Apple Intelligence to create chapter markers when publishers haven't supplied any. Up Next also reads chapters from podcast feeds, audio metadata and supported show-note formats. AI generation requires a compatible device/model.
- **Skip chapters automatically by keyword.** Match chapter titles using **contains**, **equals**, **starts with** or **ends with** rules; configure global or per-podcast behavior. You can also toggle individual chapters on and off.
- **Recover from accidental skips.** Undo an unintended seek or skip and return to the previous episode and position.
- **Follow live podcasts.** Discover and play currently live episodes from Podcasting 2.0 `podcast:liveItem` metadata in your subscriptions.
- **Choose your own listening workflow.** Curate multiple playlists, route podcasts to playlists, configure playlist-specific downloads, save timestamped bookmarks, export audio/video clips, and listen together with SharePlay.
- **Keep podcasting open.** Free and MIT-licensed, without a premium tier, in-app ads, or an Up Next account. Feed refresh and analysis run on your devices, while optional Apple iCloud/CloudKit keeps your listening state in sync.

## Feature comparison

_Updated October 2026. Focused on distinctive listening, transcript, and chapter features rather than basic play/pause/download capabilities._

| Feature | **Up Next** | Apple Podcasts | Overcast | Pocket Casts | Castro | opencast | AntennaPod |
|:--|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **Price (Germany, Oct 2026)** | **Free · no paid tier** | Free · paid shows optional | Free · Premium €34.99/year | Free · Plus €44.99/year / Patron €99.99/year | Free · Plus €24.99/year | Free · optional transcription credits €0.99–€5.99 | Free · donations optional |
| **On-device transcription for missing episodes** | **✅** | — | ✅ | — | — | ✅ | — |
| **Automatically transcribe after download** | **✅** | — | — | — | — | — | — |
| **Full-library transcript search (across episodes)** | **✅** | — | — | — | — | ✅ | — |
| **Search spoken text within a podcast/show** | **✅** | ✅¹ | — | — | — | — | — |
| Search the current episode's transcript | ✅ | ✅ | ✅ | ✅ | — | ✅ | — |
| **Generate missing chapters on-device with AI** | **✅** | — | — | — | — | — | — |
| Automatically generated chapters (any method) | ✅ | ✅² | — | ◐³ | — | ◐⁴ | — |
| **Automatic chapter skipping by keyword rules** | **✅** | — | ◐⁵ | — | — | — | — |
| Manually choose which chapters play | ✅ | — | ◐⁵ | ◐⁶ | — | — | — |
| **Detect / automatically skip inserted ads** | **🧪** | — | — | — | — | ✅ | — |
| **Dedicated Podcasting 2.0 live-podcast player** | **✅** | — | — | — | — | — | — |
| **Accidental seek/skip undo** | **✅** | — | — | — | — | — | — |
| Timestamped episode bookmarks | ✅ | — | — | ◐⁶ | — | — | — |
| Audio/video clip creation and sharing | ✅ | ◐⁷ | ✅ | ◐⁸ | — | — | — |
| Multiple manually curated playlists | ✅ | — | ✅ | ✅ | — | — | — |
| Playlist-specific automatic downloads | ✅ | — | ◐ | ✅ | — | — | — |
| **Browse dedicated public-broadcaster directories** | **✅** | — | — | — | — | — | — |
| Synchronized listening via SharePlay | ✅ | — | — | — | — | — | — |
| Native iPhone **and** macOS apps | ✅ | ✅ | — | ◐⁹ | — | — | — |
| Completely free app without premium features | ✅ | ✅¹⁰ | — | — | — | — | ✅ |
| Open-source app | ✅ | — | — | ✅ | — | ✅ | ✅ |

**Legend:** ✅ Supported · ◐ Partial, different approach, or paid feature · 🧪 Implemented experimentally / optional (not a promise of perfect detection) · — No equivalent confirmed in the linked public documentation. Entries describe capabilities, not reliability or quality. Features vary by app version, subscription, device and region.

**Pricing notes (German App Store, checked 8 October 2026):** Listed subscriptions are optional yearly plans for new customers; monthly billing, regional pricing, taxes and legacy rates may differ. Overcast lists lower-priced legacy Premium tiers. Pocket Casts also offers Plus at €3.99/month and Patron at €9.99/month; Castro Plus is also €3.99/month. opencast's €0.99 (20 hours) and €5.99 (100 hours) are optional one-time *remote transcription* credits, not a subscription; on-device transcription remains free. Apple Podcasts itself is free, but publishers may charge for shows. Up Next and AntennaPod have no paid feature tiers. Check [Up Next](https://apps.apple.com/de/app/up-next-podcast-client/id6477821584), [Apple Podcasts](https://apps.apple.com/de/app/apple-podcasts/id525463029), [Overcast](https://apps.apple.com/de/app/overcast-podcast-app/id888422857), [Pocket Casts](https://apps.apple.com/de/app/pocket-casts-podcast-player/id414834813), [Castro](https://apps.apple.com/de/app/castro-podcast-app-player/id1080840241), [opencast](https://apps.apple.com/de/app/opencast-podcast-player/id6766770733), and [AntennaPod](https://antennapod.org/) for current prices.

**Important distinctions and limitations**

1. **Apple Podcasts** introduced **Search in Show** in iOS 27, including matches from a show's transcripts. This is not the same as searching transcript text across *your entire library*.
2. **Apple Podcasts** automatically creates chapters for eligible English-language catalog episodes on Apple's side; it does not provide Up Next's on-device chapter generator for arbitrary locally available transcripts.
3. **Pocket Casts** has supported server-generated AI chapters, but its [documentation currently says that generation is temporarily switched off](https://support.pocketcasts.com/knowledge-base/chapters/).
4. **opencast** offers generated chapters/summaries via optional transcript-processing services/paid usage; its transcription can also run on-device.
5. **Overcast** added on-device transcription and single-episode transcript search in 2026. Its premium chapter preselection can remember *recurring chapter titles* across episodes, but is not the same as Up Next's configurable contains/equals/starts-with/ends-with keyword rules.
6. **Pocket Casts Plus/Patron** supports manually preselecting chapters and timestamped bookmarks. It also has multiple manual and smart playlists, plus playlist auto-download.
7. **Apple Podcasts** can share from a transcript position; that is not the same as exporting a standalone edited clip file.
8. **Pocket Casts** supports clip sharing with a playable share link, rather than the same local audio/video file-export workflow.
9. **Pocket Casts** offers desktop players, but they are not native SwiftUI macOS apps.
10. **Apple Podcasts** is free to use as a client, while individual publisher subscriptions can be paid. Likewise, paid podcast feeds are compatible with Up Next without creating an Up Next premium tier.

**Up Next implementation links:** [transcription](Raul/Features/Transcripts/Services/AITranscripts.swift) · [**full transcript search**](Raul/Features/Transcripts/Services/TranscriptSearchService.swift) · [on-device chapter generation](Raul/Features/Chapters/Models/AIChapter.swift) · [keyword-based chapter skipping](Raul/Shared/Actors/EpisodeActor.swift) · [live podcasts](Raul/Features/Playlist/Views/LivePodcastsView.swift) · [skip recovery](Raul/Features/Player/Classes/Player.swift) · [SharePlay](Raul/Features/SharePlay/ListenTogether.swift).

**Competitor documentation:** [Apple Podcasts chapters](https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts) · [Apple Podcasts iOS 27 Search in Show](https://podcasters.apple.com/support/5612-iOS-27-whats-new-for-apple-podcasts) · [Overcast features](https://overcast.fm/) / [2026 app updates](https://apps.apple.com/us/app/overcast-podcast-app/id888422857) · [Pocket Casts transcripts](https://support.pocketcasts.com/knowledge-base/episode-transcripts/) / [chapter preselection](https://support.pocketcasts.com/knowledge-base/preselect-chapters/) / [playlists](https://support.pocketcasts.com/knowledge-base/playlists/) · [Castro](https://apps.apple.com/us/app/castro-podcast-app-player/id1080840241) · [opencast](https://apps.apple.com/us/app/opencast-podcast-player/id6766770733) · [AntennaPod](https://antennapod.org/documentation/).
