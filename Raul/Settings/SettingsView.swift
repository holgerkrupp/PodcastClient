//
//  SettingsView.swift
//  Raul
//
//  Created by Holger Krupp on 20.05.25.
//

import SwiftUI
import Foundation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var pendingDeletion: StorageArea?

    var body: some View {
        NavigationStack {
            List {
                Section("Playback & Queue") {
                    NavigationLink {
                        PodcastSettingsView(podcast: nil, modelContainer: modelContext.container)
                    } label: {
                        Label("Global Playback Settings", systemImage: "slider.horizontal.3")
                    }
                }

                Section("Integrations") {
                    NotificationSettingsView()

                    NavigationLink {
                        TranscriptionSettingsView()
                    } label: {
                        Label("Transcriptions", systemImage: "waveform.and.mic")
                    }
                }

                Section("Maintenance") {
                    Button("Rebuild Listening Analytics") {
                        let container = modelContext.container
                        Task {
                            await PlaySessionTrackerActor(modelContainer: container).rebuildListeningStats()
                        }
                    }

                    Button("Delete Documents Files", role: .destructive) {
                        pendingDeletion = .documents
                    }

                    Button("Delete Cache Files", role: .destructive) {
                        pendingDeletion = .caches
                    }
                }

                Section {
                    CreatedByView()
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .confirmationDialog(
                pendingDeletion?.title ?? "Delete Files",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { isPresented in
                        if isPresented == false {
                            pendingDeletion = nil
                        }
                    }
                )
            ) {
                if let pendingDeletion {
                    Button("Delete", role: .destructive) {
                        deleteAllFiles(in: pendingDeletion.directory)
                        self.pendingDeletion = nil
                    }
                }

                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text("This removes files from the selected app folder but keeps the database and subscriptions.")
            }
        }
    }

    private func deleteAllFiles(in folder: FileManager.SearchPathDirectory, excluding excludedFileName: String = "log.txt") {
        let fileManager = FileManager.default

        guard let folderURL = fileManager.urls(for: folder, in: .userDomainMask).first else {
            return
        }

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)

            for fileURL in fileURLs where fileURL.lastPathComponent != excludedFileName {
                try? fileManager.removeItem(at: fileURL)
            }
        } catch {
        }
    }
}

private enum StorageArea {
    case documents
    case caches

    var title: String {
        switch self {
        case .documents:
            "Delete documents files?"
        case .caches:
            "Delete cache files?"
        }
    }

    var directory: FileManager.SearchPathDirectory {
        switch self {
        case .documents:
            .documentDirectory
        case .caches:
            .cachesDirectory
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(ModelContainerManager.shared.container)
}
