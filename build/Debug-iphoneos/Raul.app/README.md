# PodcastClient

## Open Source Podcast Client

I started developing an open source podcast client in 2023 with the goal of building something that doesn’t rely on a central server. By 2024 I had a working alpha that already included features like transcripts, accidental skip detection, and other improvements I felt were missing from existing podcast apps.

This isn’t my first attempt at building a podcast app — I actually released my first client, **One Trick Pony**, about nine years ago. Life took me in other directions for a while, but now I’m back at it—this time starting almost from scratch. I’m targeting iOS 26, adopting Swift 6, and following its strict concurrency rules to avoid race conditions. Some parts of the old codebase will be reused, but the foundation is fresh.

The goal of this project is simple: **give back to the community.** I’ve enjoyed countless free podcasts over the last 20 years, and I also use free tools like Podlove Publisher and Ultraschall to publish my own. This app is my way of helping preserve podcasting as an open, independent medium—resisting efforts by companies to lock it down.

Key principles of the project:

* Built on the community-driven podcast catalog [fyyd](https://fyyd.de/)
* Independent of proprietary servers (all refreshes run locally on-device)
* 100% open source and free to use
* No locked features or restrictions


### Next Steps

- [x] Integrate Settings (Per Podcasts and global)
- [x] Use Notification Center to send notification to the player if settings are changed.

- [x] fix Skip Chapters (validate skip to and skip last)

- [ ] Refactor mp3ChapterReader to send a custom object (concurrency)
- [x] mp3ChapterReader work with remote files



## Alpha min Requiremets

### Subscription Management
- [x] add podcast via URL

### Refresh and Downloads
- [x] refresh podcast content via Button
- [x] refresh all with pull to refresh
- [x] download episodes
- - [x] show download progress
- - [x] delete files
- - [x] implement automatic background downloads
- [x] remove all files when one episode is archived 
- [x] if Playlist contains episode, move it to the front/end instead of adding another copy

### Player
- [x] play / pause
- [x] skip forward / backward
- - [ ] make time adjustable
- [x] jump to chapter
- [x] Chapter marks
- - [x] PSC
- - [x] m4a
- - [x] mp3
- - [x] extracted from shownotes
- - [x] Update Chapter View more snappy
- [x] include chapter art for mp3/m4a
- [x] include chapter links for mp3/m4a
- [x] postprocess chapters to find duration/end if no value is given ( chapter[n].end = chapter[n+1].start ? episode.end)
- [x] save last played episode and reload when opening the app

## Beta min Requirement

### Subscription Management
- [x] OPML import
- - [x] to be validated with big file
- - [ ] Show import progress
- - [x] Handle no longer existing feeds (HTTP Status 404, 500, 410 oder 200 but HTML and no XML)
- [x] podcast directory search
- - [x] iTunes Directory Search (basic)
- - [x] Fyyd Directory Search
- - [x] Fyyd recomendations


### Refresh and Downloads
- [x] auto download/refresh feeds

### Player
- [x] skip manually selected chapters
- [x] sleep timer
- [x] play next queue
- [x] set playbackspeed
- - [x] (per podcast)



## 1.0 min requirements

### Miscellaneous
- [x] nice UI
- [x] nice Logo
- [x] nice name - Up Next
- [x] CarPlay

### Subscription Management
- [x] OPML export




### Refresh and Downloads
- [x] Automatic deletion of files
- - [x] Based on time passed since release 
- [x] Notification after refresh

### Player
- [ ] skip detection
- [x] share Episode
- - [x] from play now screen
- - [x] from episode view screen
- - [x] (including Playposition if possible)




##1.1 min requirements 

### Subscription Management
- [ ] Sideloads via iCloud Drive
- [ ] Downloads of Episodes withouth subscribing to a feed

- [ ] accept opml from share sheet
- [ ] accept rss / xml from share sheet 
- [ ] accept any URL that could be a feed

### Refresh and Downloads

### Player

- [ ] custom playlists


##1.x requirements
- [x] Transkripts
-   -  [ ] optimized Transcipts view (long text)
- [ ] Apple Watch App
- [ ] remove tracking information from URLs
- [x] share little videos from episodes for social media
- [ ] provide suggestions for apple Journal App (https://developer.apple.com/documentation/journalingsuggestions)
