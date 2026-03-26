import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchSyncStore
    @State private var isShowingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                WatchPlaylistPage(isShowingSettings: $isShowingSettings)
            }

            NavigationStack {
                WatchInboxPage()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                WatchStorageSettingsView()
                    .environmentObject(store)
            }
        }
        .alert(
            "Up Next Watch",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct WatchPlaylistPage: View {
    @EnvironmentObject private var store: WatchSyncStore
    @Binding var isShowingSettings: Bool

    var body: some View {
        Group {
            if store.playlist.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.title2)
                    Text("Up Next is empty")
                        .font(.headline)
                    Button("Sync Now") {
                        store.requestSnapshot()
                    }
                }
                .padding()
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(store.usedStorageDescription) of \(store.storageLimitDescription) used")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Episodes that do not fit stay visible here and can be downloaded on demand.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(store.playlist) { episode in
                        WatchPlaylistRow(episode: episode)
                    }
                }
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }
}

private struct WatchPlaylistRow: View {
    @EnvironmentObject private var store: WatchSyncStore
    let episode: WatchSyncEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(2)

            if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                Text(podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if store.isDownloaded(episode) {
                HStack {
                    Label("On Watch", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)

                    Spacer()

                    Button("Remove") {
                        store.removeDownload(episode)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else {
                Button {
                    store.downloadEpisode(episode)
                } label: {
                    Label(
                        store.isDownloading(episode) ? "Downloading" : "Download",
                        systemImage: store.isDownloading(episode) ? "arrow.down.circle.fill" : "arrow.down.circle"
                    )
                }
                .disabled(store.isDownloading(episode))
                .buttonStyle(.borderedProminent)

                if episode.phoneHasLocalFile {
                    Text("The iPhone already has this download. It will sync here automatically when space is available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WatchInboxPage: View {
    @EnvironmentObject private var store: WatchSyncStore

    var body: some View {
        Group {
            if store.inbox.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.title2)
                    Text("Inbox is empty")
                        .font(.headline)
                    Button(store.isRefreshingInbox ? "Refreshing…" : "Refresh Inbox") {
                        store.refreshInbox()
                    }
                    .disabled(store.isRefreshingInbox)
                }
                .padding()
            } else {
                List(store.inbox) { episode in
                    WatchInboxRow(episode: episode)
                }
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.refreshInbox()
                } label: {
                    if store.isRefreshingInbox {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingInbox)
            }
        }
    }
}

private struct WatchInboxRow: View {
    @EnvironmentObject private var store: WatchSyncStore
    let episode: WatchSyncEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(2)

            if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                Text(podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(episode.resolvedAudioURL == nil ? "Add to Up Next" : "Queue + Download") {
                store.queueEpisode(episode, downloadAfterQueue: episode.resolvedAudioURL != nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 2)
    }
}
