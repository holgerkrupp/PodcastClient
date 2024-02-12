//
//  PodcastSettingsView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 13.01.24.
//

import SwiftUI

struct PodcastSettingsView: View {
    
    @State var settings:PodcastSettings
    
    var body: some View {
        List{
            
            Section {
                
                Toggle(isOn: $settings.markAsPlayedAfterSubscribe) {
                    Text("Mark existing episodes as played")
                }
                
                
                
                
            } header: {
                Text("Import Management")
            } footer: {
                Text("These Settings are applied when a feed is subscribed")
            }
            
            /*
            Section {
    
                Toggle(isOn: $settings.playSumAdjustedbyPlayspeed) {
                    Text("Show Play time sum adjusted by playback speed")
                }
                
            } header: {
                Text("Global Settings")
            } footer: {
                Text("These Settings are applied to all podcasts/episodes")
            }
            */
            
            Section {
                
                    Toggle(isOn: $settings.autoDownload) {
                        Text("Auto download new Episodes")
                    }
                
                Picker(selection: $settings.playnextPosition) {
                    
                    Text("do nothing").tag(Playlist.Position.none)
                    Text("at the beginning").tag(Playlist.Position.front)
                    Text("at the end").tag(Playlist.Position.end)

                } label: {
                    Text("Put new Elements to Play Next Queue")
                }


                
            } header: {
               Text("Episode Management")
            } footer: {
                Text("These Settings change how new Episodes of Podcasts are managed.")
            }
            
            
            Section {
                
                Stepper(value: $settings.playbackSpeed, in: 0.1...3.0, step: 0.1) {
                    Text("\(settings.playbackSpeed.formatted())x")
                }
                

                TextField("Cut from Front", value: $settings.cutFront, format: .number)
                TextField("Cut from End", value: $settings.cutEnd, format: .number)
                Picker(selection: $settings.skipBack) {
                    ForEach (SkipSteps.allCases, id:\.self) { skip in
                        Text("\(skip.rawValue.formatted()) seconds")
                    }
                } label: {
                    HStack{
                        Image(systemName: "gobackward")
                        Text("Skip back")
                    }
                }
                Picker(selection: $settings.skipForward) {
                    ForEach (SkipSteps.allCases, id:\.self) { skip in
                        Text("\(skip.rawValue.formatted()) seconds")
                    }
                } label: {
                    HStack{
                        Image(systemName: "goforward")
                        Text("Skip Forward")
                    }
                }

                
            } header: {
                Text("Playback Management")
            } footer: {
                Text("These Settings are applied when a new episode is loaded into the player and change the playback behaviour")
            }
            
            
            Section {
                
                Text("Settings for skipping Chapters by keyword")
                
            } header: {
                Text("Chapter Management")
            } footer: {
                Text("These Settings are applied when chapters are detected in an episode")
            }
            
            Section {
                
                Stepper(value: $settings.sleepTimerAddMinutes, in: 1...30, step: 1) {
                    Text("Extend Sleep Timer by \(settings.sleepTimerAddMinutes.formatted()) minutes")
                }
                
                
                Stepper(value: $settings.sleepTimerDurationToReactivate, in: 1...30, step: 1) {
                    Text("Play button reactivates sleep timer during \(settings.sleepTimerDurationToReactivate.formatted()) minutes after stopping playing.")
                }

                Toggle("Voice Feedback when sleep timer is extended", isOn: $settings.sleepTimerVoiceFeedbackEnabled)
            
                TextField("Sleep Timer Voice Feedback Text", text: $settings.sleepTimerText)
                    .disabled(!settings.sleepTimerVoiceFeedbackEnabled)
                
                Button {
                    SleepTimer().speak()
                } label: {
                    Text("Test Sleep Timer Voice Feedback")
                }
                .disabled(!settings.sleepTimerVoiceFeedbackEnabled)


                
                
            } header: {
                Text("Sleep Timer")
            } footer: {
                Text("When a sleep timer ends, you can press play / the air pod button to reactivate it. Here you can customize the behaviour")
            }

        }
    }
}

#Preview {
    PodcastSettingsView(settings: SettingsManager.shared.defaultSettings)
}
