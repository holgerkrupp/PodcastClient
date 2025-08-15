import SwiftUI
import SwiftData

struct PodcastSettingsView: View {
    @Environment(\.modelContext) private var context
  //  @Environment(\.modelContainer) private var modelContainer

    @Bindable var podcast: Podcast
    @State private var useCustomSettings: Bool
    var podcastTitle: String { podcast.title }
    var settings: PodcastSettings? {podcast.settings }
    private var defaultSettings: PodcastSettings?
    @Query private var allSettings: [PodcastSettings]
    @State private var actor: PodcastSettingsModelActor
  
    init(podcast: Podcast, modelContainer: ModelContainer) {
        self._podcast = .init(wrappedValue: podcast)
        self.actor = PodcastSettingsModelActor(modelContainer: modelContainer)
        self._useCustomSettings = State(initialValue: podcast.settings != nil && podcast.settings?.isEnabled == true)
        self.defaultSettings = allSettings.first(where: { $0.title == "de.holgerkrupp.podbay.queue" }) ?? PodcastSettings(defaultSettings: true)
        
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
                Task {
                    if useCustomSettings == true {
                        await actor.enableCustomSettings(for: podcast.id)
                    } else {
                        await actor.disableCustomSettings(for: podcast.id)
                    }
                }
            }

            Form {
                if let settings = settings, useCustomSettings {
                    Text("Podcast Settings for \(podcastTitle)")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                        .padding()
                        settingsSections(settings: settings)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                    
                } else {
               
                        Text("This podcast uses the global settings. To customize, switch to 'Custom Settings'.")
                        .padding()
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                    
                        if let settings = defaultSettings {
                            settingsSections(settings: settings)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.init(top: 0,
                                                     leading: 0,
                                                     bottom: 0,
                                                     trailing: 0))
                        }
                        
                    
                }
            }
            .navigationTitle(podcastTitle)
            .formStyle(.grouped)
            .background(Color.clear)
            .tint(Color.accent)
        }
        .padding()

    }

    func printAllSettings() {
        for setting in allSettings {
            print("podcast: \(setting.podcast?.title ?? "nil") - \(setting.podcast?.id.uuidString ?? "nil") - SettingID: \(setting.id.uuidString)")
        }
    }
    
    
    // All editable sections for PodcastSettings
    @ViewBuilder
    func settingsSections(settings: PodcastSettings) -> some View {
        Section(header: Text("Subscription"), footer: Text("Where should a new Episode be added to the playlist?")) {
       //     Toggle("Auto Download", isOn: binding(for: \.autoDownload, in: settings))
            Picker("Up Next Position", selection: binding(for: \.playnextPosition, in: settings)) {
                Text("Inbox").tag(Playlist.Position.none)
                Text("Top").tag(Playlist.Position.front)
                Text("Bottom").tag(Playlist.Position.end)
            }
            
        }
        
        
        Section(header: Text("Playback"), footer: Text("")) {

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
        



        Section(header: Text("Chapter Skip Keywords"), footer: Text("Chapters containing any of these keywords will be skipped during playback.")) {
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
                    .buttonStyle(.plain)
                }
            }
            Button(action: {
                settings.autoSkipKeywords.append(skipKey())
            }) {
                Label("Add Keyword", systemImage: "plus")
            }
        }
/*
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

*/

     
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
            if let container = ModelContainerManager().container{
                // Pass a valid ModelContainer instance for previews
                PodcastSettingsView(podcast: podcastWithCustomSettings, modelContainer:container)
                    .previewDisplayName("Podcast with Custom Settings")
                
                let podcastWithoutCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
                PodcastSettingsView(podcast: podcastWithoutCustomSettings, modelContainer: container)
                    .previewDisplayName("Podcast with Global Settings")
            }
        }
    }
}
#endif
