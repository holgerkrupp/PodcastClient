//
//  ImportExportView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    @Environment(\.modelContext) private var context

    @State private var importing = false
    @State private var newPodcasts: [PodcastFeed] = []
    @State private var fileURL: URL?
    @State private var isPreparingExport = false
    @State private var importErrorMessage: String?
    @State private var exportErrorMessage: String?

    private let applePodcastsShortcutURL = URL(string: "https://www.icloud.com/shortcuts/5e49239698c44e92baf94399df86b3f9")!

    private let transferGuides = [
        TransferGuide(
            title: "Apple Podcasts",
            icon: "apple.logo",
            tint: .pink,
            steps: [
                "Install the Apple Podcasts to OPML shortcut.",
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
            }

            Section {
                Button {
                    importing = true
                } label: {
                    actionCard(
                        title: "Import OPML",
                        subtitle: "Choose an OPML or XML file and preview what is new.",
                        icon: "square.and.arrow.down.on.square.fill",
                        tint: .cyan,
                        trailingIcon: "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .fileImporter(
                    isPresented: $importing,
                    allowedContentTypes: [.opml, .xml]
                ) { result in
                    switch result {
                    case .success(let file):
                        let modelContainer = context.container
                        let fileURL = file.absoluteURL
                        Task {
                            let imported = await Task.detached(priority: .utility) {
                                await SubscriptionManager(modelContainer: modelContainer).read(file: fileURL) ?? []
                            }.value
                            await MainActor.run {
                                importErrorMessage = nil
                                newPodcasts = imported
                            }
                        }
                    case .failure(let error):
                        importErrorMessage = error.localizedDescription
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
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))
                } header: {
                    Text("Import Preview")
                }
            }

            if !pendingPodcasts.isEmpty {
                Section {
                    Button {
                        subscribePendingPodcasts()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.headline)
                            Text("Subscribe to All New Podcasts")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
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
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 4, leading: 14, bottom: 8, trailing: 14))

                    ForEach(pendingPodcasts, id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                    }
                } header: {
                    Text("Ready to Subscribe (\(pendingPodcasts.count))")
                }
            }

            if !existingPodcasts.isEmpty {
                Section {
                    ForEach(existingPodcasts, id: \.url) { newPodcastFeed in
                        SubscribeToPodcastView(newPodcastFeed: newPodcastFeed)
                            .modelContext(context)
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
                previewStat(title: "Loaded", count: newPodcasts.count, tint: .blue)
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

            if guide.showsShortcutLink {
                Link(destination: applePodcastsShortcutURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                        Text("Install Apple Podcasts Shortcut")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(guide.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(guide.tint.opacity(0.12))
                    )
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

    private func previewStat(title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func prepareExportFileIfNeeded() async {
        if fileURL == nil {
            await sharePodcasts()
        }
    }

    private func subscribePendingPodcasts() {
        let toSubscribe = pendingPodcasts
        let modelContainer = context.container
        Task {
            await Task.detached(priority: .utility) {
                await SubscriptionManager(modelContainer: modelContainer).subscribe(all: toSubscribe)
            }.value
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

#Preview {
    ImportExportView()
}

public extension UTType {

    static var opml: UTType {
        UTType("public.opml")!
    }
}
