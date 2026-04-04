//
//  PlaylistEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI
import SwiftData
import CloudKit

struct PlaylistEmptyView: View {
    private enum CloudSyncState {
        static let containerID = "iCloud.de.holgerkrupp.PodcastClient"
    }
    
    @Query private var allPodcasts: [Podcast]
    @State private var expectedRemoteLibraryData = false
    @State private var cloudAccountAvailable = false

    private var shouldShowCloudSyncHint: Bool {
        allPodcasts.isEmpty && (expectedRemoteLibraryData || cloudAccountAvailable)
    }
    
    var body: some View {
        if allPodcasts.isEmpty {
            Group {
                if shouldShowCloudSyncHint {
                    cloudSyncHint
                } else {
                    PodcastsEmptyView()
                }
            }
            .task {
                refreshCloudSyncExpectation()
                await refreshCloudAccountStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
                refreshCloudSyncExpectation()
            }
        }else{
            
            VStack{
                Text("Your Playlist is empty")
                    .font(.headline)
                Divider()
                Text("Add episodes from your subscribed podcasts to listen to. The episodes will be played in the order they were added to your playlist. You can rearrange them by dragging them in the list.")
            }
            .padding()
        }
    }

    @ViewBuilder
    private var cloudSyncHint: some View {
        VStack{
            Text("Syncing from iCloud")
                .font(.headline)
            Divider()
            Text("Your library exists on another device. Podcasts should appear here shortly.")
        }
        .padding()
    }

    private func refreshCloudSyncExpectation() {
        expectedRemoteLibraryData = CloudSyncExpectationStore.hasExpectedRemoteData()
    }

    private func refreshCloudAccountStatus() async {
        let container = CKContainer(identifier: CloudSyncState.containerID)
        do {
            let status = try await container.accountStatus()
            await MainActor.run {
                cloudAccountAvailable = (status == .available)
            }
        } catch {
            await MainActor.run {
                cloudAccountAvailable = false
            }
        }
    }
}

#Preview {
    PlaylistEmptyView()
}
