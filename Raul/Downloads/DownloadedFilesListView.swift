//
//  DownloadedFilesListView.swift
//  Raul
//
//  Created by Holger Krupp on 05.09.25.
//

import SwiftUI
import SwiftData

struct DownloadedFilesListView: View {
    @Environment(DownloadedFilesManager.self) private var filesManager
    @Environment(\.modelContext) private var modelContext

    @State private var sizesCache: [URL: Int] = [:]
    @State private var episodeCache: [URL: Episode] = [:]
    @State private var isRefreshing = false

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesActualByteCount = false
        return f
    }()

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView("No Downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Downloaded files will appear here."))
            } else {
                ForEach(files, id: \.self) { url in
                    NavigationLink {
                        if let episode = episodeCache[url] {
                            // Replace with your EpisodeDetailView if available in this scope
                            EpisodeQuickDetail(episode: episode)
                        } else {
                            FileQuickDetail(url: url, sizeText: sizeString(for: url))
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if let episode = episodeCache[url] {
                                    Text(episode.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(episode.podcast?.title ?? episode.author ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(sizeString(for: url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(url.lastPathComponent)
                                        .lineLimit(2)
                                    Text(sizeString(for: url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .contextMenu {
                        Button {
                            refreshSize(for: url, force: true)
                        } label: {
                            Label("Refresh Size", systemImage: "arrow.clockwise")
                        }
                        Button {
                            resolveEpisode(for: url, force: true)
                        } label: {
                            Label("Find Episode", systemImage: "magnifyingglass")
                        }
                        Button(role: .destructive) {
                            deleteFile(at: url)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .help("Refresh file list, sizes, and episode links")
            }
        }
        .onAppear {
            filesManager.refreshDownloadedFiles()
            warmSizes()
            warmEpisodes()
        }
        .onChange(of: filesManager.downloadedFiles) {
            warmSizes()
            warmEpisodes()
        }
    }

    private var files: [URL] {
        filesManager.downloadedFiles
            .sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending })
    }

    // MARK: - File sizes

    private func sizeString(for url: URL) -> String {
        if let bytes = sizesCache[url] {
            return formatter.string(fromByteCount: Int64(bytes))
        } else {
            refreshSize(for: url)
            return "—"
        }
    }

    private func refreshSize(for url: URL, force: Bool = false) {
        if !force, sizesCache[url] != nil { return }
        Task.detached(priority: .utility) {
            let bytes = await fileSize(at: url)
            await MainActor.run {
                sizesCache[url] = bytes
            }
        }
    }

    private func warmSizes() {
        let current = Set(files)
        sizesCache.keys.filter { !current.contains($0) }.forEach { sizesCache.removeValue(forKey: $0) }
        current.forEach { refreshSize(for: $0) }
    }

    private func fileSize(at url: URL) async -> Int {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return size
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.intValue
        }
        return 0
    }

    // MARK: - Episode resolution

    private func warmEpisodes() {
        let current = Set(files)
        episodeCache.keys.filter { !current.contains($0) }.forEach { episodeCache.removeValue(forKey: $0) }
        current.forEach { resolveEpisode(for: $0) }
    }

    private func resolveEpisode(for fileURL: URL, force: Bool = false) {
        if !force, episodeCache[fileURL] != nil { return }

        Task { @MainActor in
            // Entire operation on MainActor to avoid moving PersistentModels across actors
            let descriptor = FetchDescriptor<Episode>()
            let episodes = (try? modelContext.fetch(descriptor)) ?? []

            if let match = episodes.first(where: { $0.localFile?.standardizedFileURL == fileURL.standardizedFileURL }) {
                episodeCache[fileURL] = match
            }
        }
    }

    // MARK: - Actions

    private func refreshAll() {
        isRefreshing = true
        filesManager.refreshDownloadedFiles()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                warmSizes()
                warmEpisodes()
                isRefreshing = false
            }
        }
    }

    private func deleteFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Optionally show an alert
        }
        filesManager.refreshDownloadedFiles()
        // Also clear any episode link for this file
        episodeCache.removeValue(forKey: url)
    }
}

// MARK: - Simple detail placeholders

private struct EpisodeQuickDetail: View {
    let episode: Episode
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(episode.title)
                .font(.title2)
                .bold()
            if let podcast = episode.podcast?.title {
                Text(podcast)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let duration = episode.duration {
                Text("Duration: " + Duration.seconds(duration).formatted(.units(width: .narrow)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Episode")
    }
}

private struct FileQuickDetail: View {
    let url: URL
    let sizeText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.lastPathComponent)
                .font(.headline)
            Text(sizeText)
                .foregroundStyle(.secondary)
            Text(url.path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding()
        .navigationTitle("File")
    }
}

#Preview {
    NavigationStack {
        let tempFolder = FileManager.default.temporaryDirectory
        let manager = DownloadedFilesManager(folder: tempFolder)
        DownloadedFilesListView()
            .environment(manager)
            .modelContainer(ModelContainerManager.shared.container)
    }
}
