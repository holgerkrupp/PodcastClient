import SwiftUI
import SwiftData

struct PodcastSettingsView: View {
    @Environment(\.modelContext) private var context

    @Bindable var podcast: Podcast
    @State private var useCustomSettings: Bool
    var podcastTitle: String { podcast.title }
    var settings: PodcastSettings? { podcast.settings }
  
    init(podcast: Podcast) {
        self._podcast = .init(wrappedValue: podcast)
        self._useCustomSettings = State(initialValue: podcast.settings != nil)
    }

    var body: some View {
        VStack {
            Picker("Settings Mode", selection: $useCustomSettings) {
                Text("Use Global Settings").tag(false)
                Text("Use Custom Settings").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: useCustomSettings) {
                if useCustomSettings == true {
                    if podcast.settings == nil {
                        podcast.settings = PodcastSettings(podcast: podcast)
                    }
                } else {
                    podcast.settings = nil
                }
            }

            Form {
                if let settings = settings, useCustomSettings {
                    Section(header: Text("Podcast Settings for \(podcastTitle)")) {
                        settingsSections(settings: settings)
                    }
                } else {
                    Section {
                        Text("This podcast uses the global settings. To customize, switch to 'Custom Settings'.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(podcastTitle)
        }
    }

    // All editable sections for PodcastSettings
    @ViewBuilder
    func settingsSections(settings: PodcastSettings) -> some View {
        Section(header: Text("Playback")) {
            Toggle("Auto Download", isOn: binding(for: \.autoDownload, in: settings))
            Picker("Play Next Position", selection: binding(for: \.playnextPosition, in: settings)) {
                Text("None").tag(Playlist.Position.none)
                Text("Top").tag(Playlist.Position.front)
                Text("Bottom").tag(Playlist.Position.end)
            }
            HStack {
                Text("Playback Speed")
                Spacer()
                Text(String(format: "%.1fx", settings.playbackSpeed ?? 1.0))
            }
            Slider(value: Binding(
                get: { settings.playbackSpeed ?? 1.0 },
                set: { settings.playbackSpeed = $0 }
            ), in: 0.5...3.0, step: 0.1)
        }


        Section(header: Text("Chapter Skip Keywords")) {
            ForEach(Array(settings.autoSkipKeywords.enumerated()), id: \ .offset) { idx, skipKey in
                HStack {
                    TextField("Keyword", text: Binding(
                        get: { skipKey.keyWord ?? "" },
                        set: { settings.autoSkipKeywords[idx].keyWord = $0 }
                    ))
                    Picker("Operator", selection: Binding(
                        get: { skipKey.keyOperator },
                        set: { settings.autoSkipKeywords[idx].keyOperator = $0 }
                    )) {
                        Text("Is").tag(Operator.Is)
                        Text("Contains").tag(Operator.Contains)
                        Text("StartsWith").tag(Operator.StartsWith)
                        Text("EndsWith").tag(Operator.EndsWith)
                    }
                    Button(role: .destructive) {
                        settings.autoSkipKeywords.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button(action: {
                settings.autoSkipKeywords.append(skipKey())
            }) {
                Label("Add Keyword", systemImage: "plus")
            }
        }

        Section(header: Text("Trimming")) {
            Stepper(value: Binding(
                get: { settings.cutFront ?? 0 },
                set: { settings.cutFront = $0 }
            ), in: 0...120, step: 5) {
                Text("Trim Start: \(Int(settings.cutFront ?? 0)) seconds")
            }
            Stepper(value: Binding(
                get: { settings.cutEnd ?? 0 },
                set: { settings.cutEnd = $0 }
            ), in: 0...120, step: 5) {
                Text("Trim End: \(Int(settings.cutEnd ?? 0)) seconds")
            }
        }



     
    }

    private func binding<Value>(for keyPath: ReferenceWritableKeyPath<PodcastSettings, Value>, in settings: PodcastSettings) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Preview and Preview Model
#if DEBUG
struct PodcastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            let podcastWithCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
           
            PodcastSettingsView(podcast: podcastWithCustomSettings)
                .previewDisplayName("Podcast with Custom Settings")

            let podcastWithoutCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
            PodcastSettingsView(podcast: podcastWithoutCustomSettings)
                .previewDisplayName("Podcast with Global Settings")
        }
    }
}
#endif
