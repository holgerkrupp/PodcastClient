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
                        Task {
                            let imported = await SubscriptionManager(modelContainer: context.container).read(file: file.absoluteURL) ?? []
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
        Task {
            await SubscriptionManager(modelContainer: context.container).subscribe(all: toSubscribe)
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
            let manager = SubscriptionManager(modelContainer: context.container)
            let opml = await manager.generateOPML()
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

#Preview {
    ImportExportView()
}

public extension UTType {

    static var opml: UTType {
        UTType("public.opml")!
    }
}
