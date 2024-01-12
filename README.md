# PodcastClient
As my favorite podcast client stopped working and other players I've used (and am using at the moment) don't meet some functions I got used to (pre selecting chapters to skip for example), I'm starting my own player. The goal is to create an open source podcast player

## Alpha min Requiremets

### Subscription Management
- [x] add podcast via URL

### Refresh and Downloads
- [x] refresh podcast content via Button
- [ ] refresh all with pull to refresh
- [ ] refresh all using background scheduler

- [x] download episodes
- - [x] show download progress
- - [x] delete files
- - [x] update UI after file deleted
- - [ ] implement background downloads

### Player
- [x] play / pause
- [x] skip forward / backward
- - [ ] make time adjustable
- [ ] jump to chapter
- [ ] save last played episode and reload when opening the app

## Beta min Requirement

### Subscription Management
- [x] OPML import
- - [x] to be validated with big file
- - [ ] Show import progress
- [ ] podcast directory search

### Refresh and Downloads
- [ ] auto download/refresh feeds

### Player
- [ ] skip manually selected chapters
- [ ] sleep timer
- [ ] play next queue
- [ ] custom playlists
- [ ] set playbackspeed (per podcast)



## 1.0 min requirements

### Miscellaneous
- [ ] nice UI
- [ ] nice Logo
- [ ] nice name

### Subscription Management
- [ ] OPML export

### Refresh and Downloads
- [ ] Automatic deletion of files
- - [ ] Based on last x files
- - [ ] Based on time passed since release 
- [ ] Notification after refresh

### Player
- [ ] skip detection



##1.1 min requirements 

### Subscription Management
- [ ] Sideloads via iCloud Drive

### Refresh and Downloads

### Player
- [ ] CarPlay


1.x requirements
- [ ] Transkripts
- [ ] Apple Watch App
- [ ] Statistics about played episodes/podcasts

loose Requirementlist

- [ ] no backend for refreshing feeds (for cost & reliability reasons)
- [ ] inbox/queue system
- [ ] skipping chapters
- [ ] different playback speeds per feed
- [ ] Kapitelbilder
- [ ] Optional: CarPlay / Android Auto
- [ ] Playlists/Save-Queue-Function to switch between everyday/special use
- [ ] OPML Import/Export
- [ ] some users really want a good sleep timer. No idea why.
- [ ] skip forward/back 15/30s buttons in Player UI
- [x] Shownotes with clickable links
- [ ] configurable automatic download  behavior (download all new, only keep last n episodes, no auto-download) per feed

Nice to have:
- [ ] skip intro/outro per feed (n seconds)
- [ ] Chapter Images
- [ ] fyyd.de as search engine
- [ ] avoid accidentally skipping forward or backwards
- [ ] auto-skipper skipping chapters with specific keywords
