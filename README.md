# PodcastClient
An Open Source Podcast client. 

I've started the development of an open source Podcast client that doesn't rely on a server back in 2023. I got a first working Alpha in 2024 that already incloded Transcripts, accidental skip detection and other features that I missed in other PodcastClients. Then life happend and I wouldn't find the time needed to work on the App. Now I have restarted. I'm removing my old code base and starting from scratch (nearly, I'm reusing parts that are reusable). I'm targetting iOS18 (or 19) - I will follow all restrictions Swift6 brings to avoid any race conditions. I hope this new approach will go better than before.

I'm, currently building the base functionallity, reimplementing what I have and focus on a modern design later. My first approach was to mimic a existing app that was no longer maintained. As that app now has a new owner and receives updates, I will use my own design approach.

### Next Steps
- [ ] Create Podcast Detail View
- [ ] Create Episode Detail View
- [ ] Integrate Settings (Per Podcasts and global)


## Alpha min Requiremets

### Subscription Management
- [x] add podcast via URL

### Refresh and Downloads
- [x] refresh podcast content via Button
- [x] refresh all with pull to refresh
- [x] download episodes
- - [x] show download progress
- - [x] delete files
- - [ ] update UI after file deleted
- - [ ] implement automatic background downloads
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
- - [ ] extracted from shownotes
- - [ ] Update Chapter View more snappy
- [ ] include chapter art for mp3/m4a
- [?] include chapter links for mp3/m4a
- [x] postprocess chapters to find duration/end if no value is given ( chapter[n].end = chapter[n+1].start ? episode.end)
- [ ] download images during postprocessing
- [x] save last played episode and reload when opening the app

## Beta min Requirement

### Subscription Management
- [x] OPML import
- - [x] to be validated with big file
- - [ ] Show import progress
- - [x] Handle no longer existing feeds (HTTP Status 404, 500, 410 oder 200 but HTML and no XML)
- [x] podcast directory search
- - [ ] iTunes Directory Search (basic)
- - [x] Fyyd Directory Search
- - [x] Fyyd recomendations


### Refresh and Downloads
- [ ] auto download/refresh feeds

### Player
- [ ] skip manually selected chapters
- [ ] sleep timer
- [ ] play next queue
- [x] set playbackspeed
- - [ ] (per podcast)



## 1.0 min requirements

### Miscellaneous
- [ ] nice UI
- [ ] nice Logo
- [ ] nice name - Raúl
- [ ] CarPlay

### Subscription Management
- [x] OPML export

- [ ] accept opml from share sheet
- [ ] accept rss / xml from share sheet 
- [ ] accept any URL that could be a feed


### Refresh and Downloads
- [ ] Automatic deletion of files
- - [ ] Based on last x files
- - [ ] Based on time passed since release 
- [ ] Notification after refresh

### Player
- [ ] skip detection
- [ ] share Episode
- - [ ] from play now screen
- - [ ] from episode view screen
- - [ ] (including Playposition if possible)




##1.1 min requirements 

### Subscription Management
- [ ] Sideloads via iCloud Drive
- [ ] Downloads of Episodes withouth subscribing to a feed

### Refresh and Downloads

### Player

- [ ] custom playlists


##1.x requirements
- [x] Transkripts
- [ ] Apple Watch App
- [ ] remove tracking information from URLs
- [ ] share little videos from episodes for social media
- [ ] provide suggestions for apple Journal App (https://developer.apple.com/documentation/journalingsuggestions)
