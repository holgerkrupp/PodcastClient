import SwiftUI
import SwiftData


struct PodcastSettingsView: View {
    static let defaultSettingsFilter = #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" }
    
    @Environment(\.modelContext) private var context

    @State var podcast: Podcast? = nil
    @State private var useCustomSettings: Bool
    var podcastTitle: String? { podcast?.title }
    var settings: PodcastSettings? {podcast?.settings }
    //@State private var defaultSettings: PodcastSettings? = nil
    @Query(filter: defaultSettingsFilter) var defaultSettings: [PodcastSettings]
    @Query private var allSettings: [PodcastSettings]
    @State private var actor: PodcastSettingsModelActor
  
    init(podcast: Podcast?, modelContainer: ModelContainer) {
        self._podcast = .init(wrappedValue: podcast)
        self.actor = PodcastSettingsModelActor(modelContainer: modelContainer)
        self._useCustomSettings = State(initialValue: podcast?.settings != nil && podcast?.settings?.isEnabled == true)
    }

    var body: some View {
        VStack {
            if let podcast{
                Picker("Settings Mode", selection: $useCustomSettings) {
                    Text("Global Settings").tag(false)
                    Text("Custom Settings").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: useCustomSettings) {
                    Task {
                        if  useCustomSettings == true {
                            await actor.enableCustomSettings(for: podcast.id)
                        } else {
                            await actor.disableCustomSettings(for: podcast.id)
                        }
                    }
                }
            }

            Form {
                if let settings = settings, let podcast, useCustomSettings {

                    HStack{
                        
                        CoverImageView(podcast: podcast)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                        
                        
                        VStack(alignment: .leading) {
                            Text(podcast.title)
                                .font(.headline)
                        
                        }
                    }
                        settingsSections(settings: settings)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                    
                } else {
                    if let podcast{
                        Text("This podcast uses the global settings. To customize, switch to 'Custom Settings'.")
                            .padding()
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                    }
                    if let settings = defaultSettings.first {
                            settingsSections(settings: settings)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.init(top: 0,
                                                     leading: 0,
                                                     bottom: 0,
                                                     trailing: 0))
                        }
                        
                    
                }
              
                if let settings = defaultSettings.first {
                    Text("Global Settings regarding App behavior. These are applied to all podcasts.")
                        .padding()
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                    golbalSections(settings: settings)
                        .padding()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                }
             NotificationSettingsView()
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
                Spacer()
                    .listRowBackground(Color.clear)
                CreatedByView()
                    .padding()
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
                    .frame(maxWidth: .infinity)
                
            }

            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        
            .tint(Color.accent)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8))
     //   .background(Color.clear)
        // Load default settings asynchronously here instead of init to avoid async tasks in initializers



    }

    func printAllSettings() {
        for setting in allSettings {
            // print("podcast: \(setting.podcast?.title ?? "nil") - \(setting.podcast?.id.uuidString ?? "nil") - SettingID: \(setting.id.uuidString)")
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

   
           
            Stepper(value: Binding(
                get: { settings.playbackSpeed ?? 1.0 },
                set: { settings.playbackSpeed = $0
                    saveAndNotify()
                }
            ), in: 0.5...3.0, step: 0.1){
                Text(String(format: "Playback Speed %.1fx", settings.playbackSpeed ?? 1.0))
            }
        }
    
        Section(header: Text("Chapter Skip Keywords"), footer: Text("Chapters containing any of these keywords will be skipped during playback. The rules are applied when new episodes with chapters are added.")) {
            ForEach(Array(settings.autoSkipKeywords.enumerated()), id: \ .offset) { idx, skipKey in
                HStack {
                    TextField("Keyword", text: Binding(
                        get: { skipKey.keyWord ?? "" },
                        set: { settings.autoSkipKeywords[idx].keyWord = $0
                            saveAndNotify()
                        }
                    ))
                    Picker("Operator", selection: Binding(
                        get: { skipKey.keyOperator },
                        set: { settings.autoSkipKeywords[idx].keyOperator = $0
                            saveAndNotify()
                        }
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
    
    @ViewBuilder
    func golbalSections(settings: PodcastSettings) -> some View {
        Section(header: Text("Progress Slider"), footer: Text("How should the progress slider behave?")) {

            Toggle(isOn: binding(for: \.enableInAppSlider, in: settings)) {
                Text("Now Playing Slider")
            }
            Toggle(isOn: binding(for: \.enableLockscreenSlider, in: settings)) {
                Text("Lockscreen Slider")
            }
            
        }
        
        
    }

    private func binding<Value>(for keyPath: ReferenceWritableKeyPath<PodcastSettings, Value>, in settings: PodcastSettings) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0
                saveAndNotify()
            }
        )
    }
    
    private func saveAndNotify(){
        context.saveIfNeeded()
        NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
        // print("send notification")
    }
    

}

// MARK: - Preview and Preview Model
#if DEBUG
struct PodcastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            let podcastWithCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
          
                // Pass a valid ModelContainer instance for previews
                PodcastSettingsView(podcast: podcastWithCustomSettings, modelContainer:ModelContainerManager.shared.container)
                    .previewDisplayName("Podcast with Custom Settings")
                
                let podcastWithoutCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
                PodcastSettingsView(podcast: podcastWithoutCustomSettings, modelContainer: ModelContainerManager.shared.container)
                    .previewDisplayName("Podcast with Global Settings")
            
        }
    }
}
#endif
