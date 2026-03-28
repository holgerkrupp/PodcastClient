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
                }

                Section {
                    CreatedByView()
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(ModelContainerManager.shared.container)
}
