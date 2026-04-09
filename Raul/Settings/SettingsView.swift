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
                }

                Section("Help") {
                    NavigationLink {
                        SettingsHelpView()
                    } label: {
                        Label("Using Up Next", systemImage: "questionmark.circle")
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

struct SettingsHelpView: View {
    var body: some View {
        List {
            Section("Up Next Basics") {
                Text("Up Next is your single playback queue. Episodes in this list are what the player uses for \"what comes next.\"")
                Text("Inbox is your triage area for fresh episodes. Move important ones into Up Next or archive what you do not want to keep visible.")
                Text("When an episode finishes, continuous playback can automatically start the next item from Up Next.")
            }

            Section("Queue Behavior") {
                Text("New episodes can be placed at the front, end, or not added automatically, depending on your settings.")
                Text("The currently playing episode is kept pinned at the top while playback is active.")
                Text("You can reorder Up Next manually, move an episode to the end, or remove episodes from the queue.")
            }

            Section("Chapter Skip Keywords") {
                Text("Chapter rules let you skip recurring segments like intro, ads, or outro.")
                Text("Rules are checked against chapter titles and can use operators like contains, starts with, or ends with.")
                Text("Use global rules for all podcasts, or enable custom settings for one podcast when it needs its own behavior.")
            }

            Section("Siri & Shortcuts Intents") {
                Text("Available actions now include: Resume Playback, Pause Playback, Bookmark This, Skip Forward, Skip Backward, Play Up Next, Play Next Up Next Episode, Move Current To End, and Remove Current From Up Next.")
                Text("In Apple Shortcuts, search for Up Next to add these actions to personal automations.")
                Text("For best results, keep a few Siri phrases short and specific, like \"Play Up Next\" or \"Bookmark this in Up Next.\"")
            }

            Section("Accessibility") {
                Text("VoiceOver and Voice Control use the same control names you see in the player, queue, and transcript views.")
                Text("For captions, open Transcript from an episode or the player. When a feed has no transcript, you can generate one on-device.")
                Text("Reduced Motion, Larger Text, and Differentiate Without Color are supported. If you use high contrast settings, the app increases secondary text contrast in now-playing interfaces.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Using Up Next")
        .navigationBarTitleDisplayMode(.inline)
    }
}
