//
//  ImportExportView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportExportView: View {
    @Environment(\.modelContext) private var context
    @Query private var allPodcasts: [Podcast]

    @State private var importing = false
    @State private var newPodcasts: [PodcastFeed] = []
    @State private var fileURL: URL?
    @State private var isPreparingExport = false
    @State private var isImportingOPML = false
    @State private var isSubscribing = false
    @State private var isCheckingImportedFeeds = false
    @State private var showsImportPreview = false
    @State private var importProgress: SubscriptionProgressUpdate?
    @State private var importErrorMessage: String?
    @State private var exportErrorMessage: String?
    @State private var feedPreviewLoader = OPMLImportFeedPreviewLoader()

    private var applePodcastsShortcutURL: URL? {
        Bundle.main.url(forResource: "Apple Podcasts to OPML", withExtension: "shortcut")
    }

    private let transferGuides = [
        TransferGuide(
            title: "Apple Podcasts",
            icon: "apple.logo",
            tint: .pink,
            steps: [
                "Install the included Apple Podcasts to OPML shortcut.",
                "Run it from Shortcuts to create an OPML file.",
                "Return here and tap Import OPML."
            ],
            showsShortcutLink: true
        ),
        TransferGuide(
            title: "Castro",
            icon: "square.stack.3d.up.fill",
            tint: .purple,
            steps: [
                "Open Castro Settings.",
                "Go to User Data.",
                "Tap Export Subscriptions and save the OPML file."
            ]
        ),
        TransferGuide(
            title: "Overcast",
            icon: "cloud.fill",
            tint: .orange,
            steps: [
                "Open Overcast Settings.",
                "Tap Export OPML.",
                "Save the file, then import it here."
            ]
        ),
        TransferGuide(
            title: "Pocket Casts",
            icon: "p.circle.fill",
            tint: .red,
            steps: [
                "Open Profile.",
                "Open Settings.",
                "Choose Import & Export OPML, then export your subscriptions."
            ]
        )
    ]

    private var pendingPodcasts: [PodcastFeed] {
        newPodcasts
            .filter { !$0.existing && !$0.added }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var unavailablePodcasts: [PodcastFeed] {
        pendingPodcasts.filter { $0.status?.isDeadFeedResponse == true }
    }

    private var subscribablePendingPodcasts: [PodcastFeed] {
        pendingPodcasts.filter { $0.status?.isDeadFeedResponse != true }
    }

    private var existingPodcasts: [PodcastFeed] {
        newPodcasts
            .filter { $0.existing }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    var body: some View {
        List {
            Section {
                overviewCard
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 8, leading: 14, bottom: 8, trailing: 14))

                if !newPodcasts.isEmpty {
                    Button {
                        showsImportPreview = true
                    } label: {
                        actionCard(
                            title: "Review OPML Import",
                            subtitle: importPreviewSubtitle,
                            icon: "list.bullet.rectangle.portrait.fill",
                            tint: .green,
                            trailingIcon: "chevron.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 14, bottom: 8, trailing: 14))
                }
            }

            Section {
                Button {
                    importing = true
                } label: {
                    actionCard(
                        title: isImportingOPML ? "Importing OPML" : "Import OPML",
                        subtitle: isImportingOPML ? (importProgress?.message ?? "Preparing import preview...") : "Choose an OPML or XML file and preview what is new.",
                        icon: isImportingOPML ? "hourglass" : "square.and.arrow.down.on.square.fill",
                        tint: .cyan,
                        trailingIcon: isImportingOPML ? "clock" : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImportingOPML || isCheckingImportedFeeds || isSubscribing)
                .opacity(isImportingOPML || isCheckingImportedFeeds || isSubscribing ? 0.6 : 1)
                .fileImporter(
                    isPresented: $importing,
                    allowedContentTypes: [.opml, .xml]
                ) { result in
                    switch result {
                    case .success(let file):
                        let modelContainer = context.container
                        let fileURL = file.absoluteURL
                        Task {
                            await MainActor.run {
                                isImportingOPML = true
                                isCheckingImportedFeeds = false
                                isSubscribing = false
                                importErrorMessage = nil
                                importProgress = SubscriptionProgressUpdate(0, "Preparing OPML import")
                                newPodcasts = []
                            }
                            let imported = await Task.detached(priority: .utility) {
                                await SubscriptionManager(modelContainer: modelContainer).read(file: fileURL) { update in
                                    await MainActor.run {
                                        importProgress = update
                                    }
                                } ?? []
                            }.value
                            await MainActor.run {
                                newPodcasts = imported
                                showsImportPreview = imported.isEmpty == false
                                importProgress = SubscriptionProgressUpdate(0.82, imported.isEmpty ? "No subscriptions found" : "Checking feed availability")
                            }
                            await validateImportedFeeds(imported)
                            await MainActor.run {
                                isImportingOPML = false
                                importProgress = imported.isEmpty
                                    ? nil
                                    : SubscriptionProgressUpdate(1, "Import preview ready")
                            }
                        }
                    case .failure(let error):
                        importErrorMessage = error.localizedDescription
                        isImportingOPML = false
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 4, leading: 14, bottom: 4, trailing: 14))

                if let fileURL {
                    ShareLink(item: fileURL, preview: SharePreview("Podcasts.opml")) {
                        actionCard(
                            title: "Export OPML",
                            subtitle: "Share your current podcast subscriptions.",
                            icon: "square.and.arrow.up.fill",
                            tint: .indigo,
                            trailingIcon: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 4, leading: 14, bottom: 4, trailing: 14))
                } else {
                    actionCard(
                        title: isPreparingExport ? "Preparing Export" : "Export OPML",
                        subtitle: isPreparingExport ? "Generating Podcasts.opml..." : "Create a shareable OPML file from your subscriptions.",
                        icon: isPreparingExport ? "hourglass" : "square.and.arrow.up.fill",
                        tint: .indigo,
                        trailingIcon: isPreparingExport ? "clock" : "arrow.clockwise"
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 4, leading: 14, bottom: 4, trailing: 14))
                }

#if DEBUG
                Button {
                    Task {
                        let actor = SubscriptionManager(modelContainer: context.container)
                        await actor.deleteAllPodcasts()
                    }
                } label: {
                    actionCard(
                        title: "Delete All Podcasts",
                        subtitle: "Debug action that removes all current subscriptions.",
                        icon: "trash.fill",
                        tint: .red,
                        trailingIcon: "exclamationmark.triangle.fill"
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 4, leading: 14, bottom: 4, trailing: 14))
#endif

                if let importErrorMessage {
                    Text(importErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 14, bottom: 0, trailing: 14))
                }

                if let exportErrorMessage {
                    Text(exportErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 14, bottom: 4, trailing: 14))
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Import from another app, review your feeds, then subscribe only to what is new.")
            }

            Section {
                ForEach(transferGuides) { guide in
                    transferGuideCard(guide)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))
                }
            } header: {
                Text("Import from Other Apps")
            } footer: {
                Text("OPML moves podcast subscriptions only. Playback history, queues, and episode progress usually stay in the original app.")
            }

            if !newPodcasts.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        previewStat(title: "New", count: pendingPodcasts.count, tint: .green)
                        previewStat(title: "Existing", count: existingPodcasts.count, tint: .orange)
                        previewStat(title: "Unavailable", count: unavailablePodcasts.count, tint: .red)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))

                    if isImportingOPML || isCheckingImportedFeeds || isSubscribing || importProgress != nil {
                        importProgressCard
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 14, bottom: 8, trailing: 14))
                    }
                } header: {
                    Text("Import Preview")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.14),
                    Color.accentColor.opacity(0.05),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Import / Export")
        .navigationDestination(isPresented: $showsImportPreview) {
            OPMLImportPreviewView(
                newPodcasts: $newPodcasts,
                isCheckingImportedFeeds: isCheckingImportedFeeds,
                isSubscribing: isSubscribing,
                importProgress: importProgress,
                feedPreviewLoader: feedPreviewLoader,
                onSubscribeAll: subscribePendingPodcasts
            )
        }
        .task {
            await prepareExportFileIfNeeded()
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Move Subscriptions in Minutes")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Import from OPML, review what is new, and export your current library whenever you need it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                previewStat(title: "New", count: pendingPodcasts.count, tint: .green)
                previewStat(title: "Existing", count: existingPodcasts.count, tint: .orange)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    private func actionCard(title: String, subtitle: String, icon: String, tint: Color, trailingIcon: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: trailingIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.2), lineWidth: 1)
        }
    }

    private func transferGuideCard(_ guide: TransferGuide) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(guide.tint.opacity(0.18))
                    Image(systemName: guide.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(guide.tint)
                }
                .frame(width: 42, height: 42)

                Text(guide.title)
                    .font(.system(.headline, design: .rounded))

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(guide.tint)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(guide.tint.opacity(0.14))
                            )

                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if guide.showsShortcutLink, let applePodcastsShortcutURL {
                ShareLink(item: applePodcastsShortcutURL) {
                    shortcutInstallLabel(tint: guide.tint)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(guide.tint.opacity(0.2), lineWidth: 1)
        }
    }

    private func shortcutInstallLabel(tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
            Text("Install Apple Podcasts Shortcut")
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func previewStat(title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private var importPreviewSubtitle: String {
        if unavailablePodcasts.isEmpty == false {
            return "\(subscribablePendingPodcasts.count) ready, \(unavailablePodcasts.count) unavailable, \(existingPodcasts.count) already in your library."
        }

        return "\(pendingPodcasts.count) new, \(existingPodcasts.count) already in your library."
    }

    private var importProgressCard: some View {
        let progress = importProgress?.fractionCompleted ?? 0
        let tint = importProgressTint

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isImportingOPML || isCheckingImportedFeeds || isSubscribing {
                    ProgressView()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
                Text(importProgress?.message ?? "Preparing subscription")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(tint)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.2), lineWidth: 1)
        }
    }

    private var importProgressTint: Color {
        if isSubscribing {
            return .green
        }

        if isImportingOPML || isCheckingImportedFeeds {
            return .cyan
        }

        return .secondary
    }

    private func prepareExportFileIfNeeded() async {
        if fileURL == nil {
            await sharePodcasts()
        }
    }

    private func subscribePendingPodcasts() {
        let toSubscribe = subscribablePendingPodcasts
        guard !toSubscribe.isEmpty, !isSubscribing else { return }
        let modelContainer = context.container
        Task {
            await MainActor.run {
                isSubscribing = true
                importProgress = SubscriptionProgressUpdate(0, "Preparing subscription")
            }
            await Task.detached(priority: .utility) {
                await SubscriptionManager(modelContainer: modelContainer).subscribe(all: toSubscribe) { update in
                    await MainActor.run {
                        importProgress = update
                    }
                }
            }.value
            await MainActor.run {
                for podcast in toSubscribe {
                    podcast.added = true
                    podcast.existing = true
                }
                importProgress = SubscriptionProgressUpdate(1, "Subscription complete")
                isSubscribing = false
            }
        }
    }

    private func validateImportedFeeds(_ feeds: [PodcastFeed]) async {
        let feedsToCheck = feeds.filter { !$0.existing && !$0.added && $0.url != nil }
        guard !feedsToCheck.isEmpty else { return }

        await MainActor.run {
            isCheckingImportedFeeds = true
            importProgress = SubscriptionProgressUpdate(0.84, "Checking 0 of \(feedsToCheck.count) feeds")
        }

        let maximumConcurrentChecks = 8
        var iterator = feedsToCheck.makeIterator()
        var started = 0
        var completed = 0

        func addNextFeedCheck(to group: inout TaskGroup<(PodcastFeed, URLstatus?)>) {
            guard started < feedsToCheck.count, let feed = iterator.next(), let url = feed.url else { return }

            started += 1
            group.addTask {
                let status = try? await url.status()
                return (feed, status ?? URLstatus(statusCode: nil, newURL: nil, lastRequest: Date()))
            }
        }

        await withTaskGroup(of: (PodcastFeed, URLstatus?).self) { group in
            for _ in 0..<min(maximumConcurrentChecks, feedsToCheck.count) {
                addNextFeedCheck(to: &group)
            }

            for await (feed, status) in group {
                completed += 1
                let fraction = 0.84 + (Double(completed) / Double(feedsToCheck.count)) * 0.14
                await MainActor.run {
                    feed.status = status
                    feed.existing = allPodcasts.contains { $0.isSubscribed && feed.matchesExistingPodcast($0) }
                    importProgress = SubscriptionProgressUpdate(
                        fraction,
                        "Checking \(completed) of \(feedsToCheck.count) feeds"
                    )
                }
                addNextFeedCheck(to: &group)
            }
        }

        await MainActor.run {
            isCheckingImportedFeeds = false
        }
    }

    private func sharePodcasts() async {
        if isPreparingExport {
            return
        }

        await MainActor.run {
            isPreparingExport = true
            exportErrorMessage = nil
        }

        do {
            let modelContainer = context.container
            let opml = await Task.detached(priority: .utility) {
                let manager = SubscriptionManager(modelContainer: modelContainer)
                return await manager.generateOPML()
            }.value
            let generatedFile = try saveToTemporaryFile(content: opml, fileName: "Podcasts.opml")
            await MainActor.run {
                fileURL = generatedFile
            }
        } catch {
            await MainActor.run {
                exportErrorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isPreparingExport = false
        }
    }

    private func saveToTemporaryFile(content: String, fileName: String) throws -> URL {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
        let fileURL = tempDirectoryURL.appendingPathComponent(fileName)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

private struct TransferGuide: Identifiable {
    let title: String
    let icon: String
    let tint: Color
    let steps: [String]
    var showsShortcutLink = false

    var id: String { title }
}

private struct OPMLImportPreviewView: View {
    @Environment(\.modelContext) private var context
    @Query private var allPodcasts: [Podcast]
    @Binding var newPodcasts: [PodcastFeed]
    let isCheckingImportedFeeds: Bool
    let isSubscribing: Bool
    let importProgress: SubscriptionProgressUpdate?
    let feedPreviewLoader: OPMLImportFeedPreviewLoader
    let onSubscribeAll: () -> Void

    private var pendingPodcasts: [PodcastFeed] {
        newPodcasts
            .filter { !$0.existing && !$0.added }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var unavailablePodcasts: [PodcastFeed] {
        pendingPodcasts.filter { $0.status?.isDeadFeedResponse == true }
    }

    private var subscribablePendingPodcasts: [PodcastFeed] {
        pendingPodcasts.filter { $0.status?.isDeadFeedResponse != true }
    }

    private var existingPodcasts: [PodcastFeed] {
        newPodcasts
            .filter { $0.existing || $0.added }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    previewStat(title: "New", count: pendingPodcasts.count, tint: .green)
                    previewStat(title: "Existing", count: existingPodcasts.count, tint: .orange)
                    previewStat(title: "Unavailable", count: unavailablePodcasts.count, tint: .red)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))
            } header: {
                Text("Import Preview")
            }

            if isCheckingImportedFeeds {
                Section {
                    importProgressCard
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 14, bottom: 8, trailing: 14))
                }
            }

            if !unavailablePodcasts.isEmpty {
                Section {
                    ForEach(unavailablePodcasts, id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed, showsBrowseNavigationLink: false)
                            .modelContext(context)
                            .task {
                                await loadPreviewIfNeeded(for: newPodcastFeed)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                    }
                } header: {
                    Text("Unavailable Feeds (\(unavailablePodcasts.count))")
                } footer: {
                    Text("These feeds returned an error code and are skipped when subscribing to all new podcasts.")
                }
            }

            if !subscribablePendingPodcasts.isEmpty {
                Section {
                    if isSubscribing {
                        subscriptionProgressCard
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))
                    } else {
                        Button {
                            onSubscribeAll()
                        } label: {
                            subscribeAllCard
                        }
                        .disabled(isCheckingImportedFeeds)
                        .buttonStyle(.plain)
                        .opacity(isCheckingImportedFeeds ? 0.55 : 1)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))
                    }

                    ForEach(subscribablePendingPodcasts, id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
                            .task {
                                await loadPreviewIfNeeded(for: newPodcastFeed)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                    }
                } header: {
                    Text("Ready to Subscribe (\(subscribablePendingPodcasts.count))")
                }
            }

            if !existingPodcasts.isEmpty {
                Section {
                    ForEach(existingPodcasts, id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
                            .task {
                                await loadPreviewIfNeeded(for: newPodcastFeed)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                    }
                } header: {
                    Text("Already in Library (\(existingPodcasts.count))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [
                    Color.green.opacity(0.12),
                    Color.accentColor.opacity(0.05),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("OPML Import")
    }

    private var subscribeAllCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.headline)
            Text(isCheckingImportedFeeds ? "Checking Feed Availability" : "Subscribe to All Available Podcasts")
                .font(.system(.headline, design: .rounded).weight(.semibold))
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Color.green)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.22), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.green.opacity(0.24), lineWidth: 1)
        }
    }

    private var subscriptionProgressCard: some View {
        let progress = importProgress?.fractionCompleted ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text(importProgress?.message ?? "Subscribing")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(.green)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.22), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.green.opacity(0.24), lineWidth: 1)
        }
    }

    private var importProgressCard: some View {
        let progress = importProgress?.fractionCompleted ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text(importProgress?.message ?? "Checking feed availability")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(.cyan)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.2), lineWidth: 1)
        }
    }

    private func previewStat(title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func loadPreviewIfNeeded(for feed: PodcastFeed) async {
        guard isSubscribing == false else { return }
        guard feed.existing == false, feed.status?.isDeadFeedResponse != true else { return }
        guard feed.needsRemotePreview, let url = feed.url else { return }
        guard let resolvedFeed = await feedPreviewLoader.preview(for: url) else { return }

        await MainActor.run {
            feed.applyPreview(from: resolvedFeed)
            feed.existing = allPodcasts.contains { $0.isSubscribed && feed.matchesExistingPodcast($0) }
        }
    }
}

private actor OPMLImportFeedPreviewLoader {
    private var cache: [URL: PodcastFeed] = [:]
    private var failedURLs = Set<URL>()
    private var tasks: [URL: Task<PodcastFeed?, Never>] = [:]

    func preview(for url: URL) async -> PodcastFeed? {
        if let cached = cache[url] {
            return cached
        }

        if failedURLs.contains(url) {
            return nil
        }

        if let task = tasks[url] {
            return await task.value
        }

        let task = Task(priority: .utility) {
            try? await PodcastParser.fetchPage(from: url, maximumEpisodes: 1).feed
        }
        tasks[url] = task

        let feed = await task.value
        tasks[url] = nil

        if let feed {
            cache[url] = feed
        } else {
            failedURLs.insert(url)
        }

        return feed
    }
}

#Preview {
    ImportExportView()
}

public extension UTType {

    static var opml: UTType {
        UTType("public.opml")!
    }
}
