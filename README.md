# PodcastClient
An Open Source Podcast client. 
[I've released a first alpha version. It still has a lot of bugs. See my announcement in the discussion area.](https://github.com/holgerkrupp/PodcastClient/discussions/16)

## Alpha min Requiremets

### Subscription Management
- [x] add podcast via URL

### Refresh and Downloads
- [x] refresh podcast content via Button
- [x] refresh all with pull to refresh
- [x] download episodes
- - [x] show download progress
- - [x] delete files
- - [x] update UI after file deleted
- - [ ] implement automatic background downloads
- [ ] remove all files when one episode is deleted (including downloaded images)
- [x] if Playlist contains episode, move it to the front/end instead of adding another copy

### Player
- [x] play / pause
- [x] skip forward / backward
- - [x] make time adjustable
- [x] jump to chapter
- [ ] Chapter marks
- - [x] PSC
- - [x] m4a
- - [ ] mp3
- - [x] extracted from shownotes
- [ ] include chapter art for mp3/m4a
- [ ] include chapter links for mp3/m4a
- [x] download images during postprocessing
- [x] save last played episode and reload when opening the app

## Beta min Requirement

### Subscription Management
- [x] OPML import
- - [x] to be validated with big file
- - [x] Show import progress
- - [ ] Handle no longer existing feeds (HTTP Status 404, 500, 410 oder 200 but HTML and no XML)
- [x] podcast directory search
- - [x] iTunes Directory Search (basic)


### Refresh and Downloads
- [x] auto download/refresh feeds

### Player
- [x] skip manually selected chapters
- [x] sleep timer
- [x] play next queue
- [x] set playbackspeed
- - [ ] (per podcast)



## 1.0 min requirements

### Miscellaneous
- [ ] nice UI
- [ ] nice Logo
- [x] nice name - Raúl
- [x] CarPlay

### Subscription Management
- [x] OPML export
- [x] Fyyd Directory Search
- [x] Fyyd recomendations
- [ ] accept opml from share sheet
- [ ] accept rss / xml from share sheet 
- [ ] accept any URL that could be a feed


### Refresh and Downloads
- [ ] Automatic deletion of files
- - [ ] Based on last x files
- - [ ] Based on time passed since release 
- [ ] Notification after refresh

### Player
- [x] skip detection
- [x] share Episode
- - [x] from play now screen
- - [x] from episode view screen
- - [ ] (including Playposition if possible)




##1.1 min requirements 

### Subscription Management
- [ ] Sideloads via iCloud Drive

### Refresh and Downloads

### Player

- [ ] custom playlists


##1.x requirements
- [x] Transkripts
- [ ] Apple Watch App
- [ ] remove tracking information from URLs
- [ ] share little videos from episodes for social media
