//
//  SubscribeToPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import SwiftData

struct SubscribeToPodcastView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var progressValue = 0.0
    @State private var progressMessage = "Preparing subscription"
    @State private var selectedPodcastID: PersistentIdentifier?

    @Query private var allPodcasts: [Podcast]
    @Bindable var newPodcastFeed: PodcastFeed

    init(newPodcastFeed: PodcastFeed) {
        self.newPodcastFeed = newPodcastFeed
        _allPodcasts = Query()
    }

    private var existingPodcast: Podcast? {
        guard let url = newPodcastFeed.url else { return nil }
        return allPodcasts.first(where: { $0.feed == url })
    }

    private var selectedPodcast: Podcast? {
        guard let selectedPodcastID else { return nil }
        return modelContext.model(for: selectedPodcastID) as? Podcast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let podcast = existingPodcast {
                PodcastRowView(podcast: podcast)
            } else {
                previewCard
            }

            HStack(spacing: 12) {
                Button(existingPodcast == nil ? "Browse Episodes" : "Open Podcast") {
                    browseEpisodes()
                }
                .buttonStyle(.glass(.clear))
                .disabled(isWorking || (existingPodcast == nil && newPodcastFeed.url == nil))

                Spacer()

                if let podcast = existingPodcast, podcast.isSubscribed {
                    Label("Subscribed", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Subscribe") {
                        subscribe()
                    }
                    .buttonStyle(.glass(.clear))
                    .disabled(isWorking || newPodcastFeed.url == nil)
                }
            }
            .padding(.horizontal, 4)

            if existingPodcast == nil {
                Text("Browse Episodes adds this podcast to your library without subscribing, so you can download or queue individual episodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if existingPodcast?.isSubscribed == false {
                Text("This podcast is already stored without a subscription. Open it to download or queue individual episodes, or subscribe to keep it refreshed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background(hiddenNavigationLink)
        .overlay {
            statusOverlay
        }
    }

    private var previewCard: some View {
        ZStack {
            CoverImageView(imageURL: newPodcastFeed.artworkURL)
                .scaledToFill()
                .frame(height: 200)
                .clipped()

            VStack(alignment: .leading) {
                HStack {
                    CoverImageView(imageURL: newPodcastFeed.artworkURL)
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)

                    VStack(alignment: .leading) {
                        Text(newPodcastFeed.title ?? "Untitled Podcast")
                            .font(.headline)

                        Spacer()

                        if let author = newPodcastFeed.artist {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        if let desc = newPodcastFeed.description {
                            Text(desc)
                                .font(.caption)
                                .lineLimit(5)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        if newPodcastFeed.url == nil {
                            Text("This feed can be previewed, but it does not expose a reusable subscribe URL.")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding()
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
            )
        }
        .frame(height: 200)
    }

    @ViewBuilder
    private var hiddenNavigationLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { selectedPodcastID != nil },
                set: { isActive in
                    if !isActive {
                        selectedPodcastID = nil
                    }
                }
            )
        ) {
            if let selectedPodcast {
                PodcastDetailView(podcast: selectedPodcast)
            } else {
                ContentUnavailableView("Podcast Not Found", systemImage: "dot.radiowaves.left.and.right")
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isWorking {
            ZStack {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(Color.clear)
                    .ignoresSafeArea()

                VStack(alignment: .center) {
                    ProgressView(value: max(progressValue, 0.02), total: 1.0)
                        .frame(width: 180)
                    Text(progressMessage)
                        .padding(.top, 8)
                    Text("\(Int(progressValue * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(.background.opacity(0.3))
            }
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
            .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
        } else if let errorMessage {
            ZStack {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(Color.clear)
                    .ignoresSafeArea()
                Text(errorMessage)
                    .padding()
            }
            .background {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(.background.opacity(0.3))
            }
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
            .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
        }
    }

    private func browseEpisodes() {
        if let existingPodcast {
            selectedPodcastID = existingPodcast.persistentModelID
            return
        }

        Task {
            guard newPodcastFeed.url != nil else {
                await MainActor.run {
                    errorMessage = "Invalid URL"
                }
                return
            }

            await MainActor.run {
                errorMessage = nil
                isWorking = true
                progressValue = 0.0
                progressMessage = "Preparing podcast"
            }

            do {
                let podcastID = try await SubscriptionManager(modelContainer: modelContext.container).addToLibrary(
                    newPodcastFeed,
                    subscribe: false
                ) { update in
                    await MainActor.run {
                        progressValue = update.fractionCompleted
                        progressMessage = update.message
                    }
                }

                await MainActor.run {
                    isWorking = false
                    selectedPodcastID = podcastID
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }

    private func subscribe() {
        Task {
            guard newPodcastFeed.url != nil else {
                await MainActor.run {
                    errorMessage = "Invalid URL"
                }
                return
            }

            await MainActor.run {
                errorMessage = nil
                isWorking = true
                progressValue = 0.0
                progressMessage = "Preparing subscription"
            }

            await SubscriptionManager(modelContainer: modelContext.container).subscribe(all: [newPodcastFeed]) { update in
                await MainActor.run {
                    progressValue = update.fractionCompleted
                    progressMessage = update.message
                }
            }

            await requestNotification()
            await MainActor.run {
                isWorking = false
            }
        }
    }

    private func requestNotification() async {
        let notificationManager = NotificationManager()
        await notificationManager.requestAuthorizationIfUndetermined()
    }
}
