//
//  SettingsView.swift
//  Raul
//
//  Created by Holger Krupp on 20.05.25.
//

import SwiftUI
import Foundation
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

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
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }

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

                    NavigationLink {
                        CloudSyncDiagnosticsView()
                    } label: {
                        Label("Cloud Sync Diagnostics", systemImage: "icloud.and.arrow.trianglehead.2.clockwise.rotate.90")
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
