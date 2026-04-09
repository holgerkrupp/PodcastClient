//
//  PlayerControllView.swift
//  Raul
//
//  Created by Holger Krupp on 27.06.25.
//
import SwiftUI
import SwiftData


struct PlayerControllView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State private var openFullTranscriptFollowingPlayback: Bool = false
    @State var showSpeedSetting:Bool = false
    @State var showSettings: Bool = false
    @ScaledMetric(relativeTo: .body) private var mediaSectionHeight: CGFloat = 360
    @ScaledMetric(relativeTo: .body) private var transcriptCardHeight: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var mediaSectionSpacing: CGFloat = 12
    
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" } ) var globalSettings: [PodcastSettings]
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack {
                
                HStack {
                    AirPlayButtonView()
                        .tint(.primary)
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                        .accessibilityHint("Choose an audio output device")
                        
                   Spacer()
               
                    Button {
                        
                        showSpeedSetting = true
                        
                    } label: {
                        
                        Label {
                            Text("Playback Settings")
                        } icon: {
                            
                            Image(systemName: "gear")
                                .tint(.primary)
                            
                        }
                        .labelStyle(.iconOnly)
                        
                        
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playback settings")
                    .accessibilityHint("Opens playback speed, sleep timer, and queue settings")
                    .accessibilityInputLabels([Text("Playback settings"), Text("Settings")])
               
                    
                    
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showSpeedSetting, content: {
                    List{
                        Section(header: Label("Playback Speed", systemImage: "gauge.with.dots.needle.50percent")) {

                            Stepper(value: $player.playbackRate, in: 0.1...3.0, step: 0.1) {
                            
                                Text(String(format: "%.1fx", player.playbackRate))
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                        }
                        
                        Section(header: Label("Sleep Timer", systemImage: "zzz")) {

                            SleepTimerView()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                            
                            Toggle(isOn: $player.stopAfterEpisode) {
                                Text("Stop after this episode")
                            }
                            .tint(.accent)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 8,
                                                 bottom: 0,
                                                 trailing: 8))
                        }

                        
                       HStack{
                           Spacer()
                           Button("Show all Settings") {
                               showSettings = true
                           }
                           .buttonStyle(.glass(.clear))
                           Spacer()

                        }
                       .listRowSeparator(.hidden)
                       .listRowBackground(Color.clear)
                       .listRowInsets(.init(top: 0,
                                            leading: 0,
                                            bottom: 0,
                                            trailing: 0))
                       
                        
                    }

                    .listStyle(.plain)
                    
                    .padding()
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                        .presentationDetents([.fraction(0.5)])
                        .sheet(isPresented: $showSettings) {
                           
                            if let podcast = player.currentEpisode?.podcast {
                                PodcastSettingsView(podcast: podcast, modelContainer: context.container, embedInNavigationStack: true)
                                        .presentationBackground(.ultraThinMaterial)
                            }else{
                                PodcastSettingsView(podcast: nil, modelContainer: context.container, embedInNavigationStack: true)
                                        .presentationBackground(.ultraThinMaterial)
                            }
                            
                        
                    }
                    
                })
                
                VStack(spacing: mediaSectionSpacing) {
                    CoverImageView(episode: episode, timecode: player.currentChapter?.start)
                        .id(episode.url)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: showTranscripts
                                ? mediaSectionHeight - transcriptCardHeight - mediaSectionSpacing
                                : mediaSectionHeight,
                            alignment: .top
                        )

                    if let transcriptLines = player.currentEpisode?.transcriptLines,
                       showTranscripts {
                        Button {
                            openFullTranscriptFollowingPlayback = true
                            showFullTranscripts = true
                        } label: {
                            TranscriptView(
                                transcriptLines: transcriptLines.sorted(by: { $0.startTime < $1.startTime }),
                                currentTime: $player.playPosition
                            )
                            .frame(maxWidth: .infinity, minHeight: transcriptCardHeight, maxHeight: transcriptCardHeight, alignment: .topLeading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Open full transcript")
                        .accessibilityHint("Opens the transcript list and jumps to the current playback line")
                        .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: mediaSectionHeight, alignment: .top)
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: showTranscripts)
                .sheet(isPresented: $showFullTranscripts, onDismiss: {
                    openFullTranscriptFollowingPlayback = false
                }) {
                    if let transcriptLines = player.currentEpisode?.transcriptLines {
                        TranscriptListView(
                            transcriptLines: transcriptLines,
                            episode: episode,
                            startFollowingPlayback: openFullTranscriptFollowingPlayback
                        )
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
                
                if let transcripts = player.currentEpisode?.transcriptLines, transcripts.count > 0 {
                    HStack {
                        if showTranscripts{
                            Button {
                                    showTranscripts.toggle()
                                } label: {
                                    Image("custom.quote.bubble.slash")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Hide inline transcript")
                                .accessibilityHint("Removes the transcript panel below the artwork")
                                .accessibilityInputLabels([Text("Hide captions"), Text("Hide transcript")])
                        }else{
                            Button {
                                    showTranscripts.toggle()
                                } label: {
                                    Image(systemName: "quote.bubble")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show inline transcript")
                                .accessibilityHint("Shows the transcript panel below the artwork")
                                .accessibilityInputLabels([Text("Show captions"), Text("Show transcript")])
                        }
                        Spacer()
                        Button {
                                openFullTranscriptFollowingPlayback = false
                                showFullTranscripts = true
                            } label: {
                                Image("custom.quote.bubble.rectangle.portrait")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open full transcript")
                            .accessibilityHint("Opens the full transcript in a sheet")
                            .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                    }
                }
                
                
                PlayerChapterView()
                
                
                Text("\(episode.title)")
                    .lineLimit(2)
                
                
                VStack {
                    PlayerProgressSliderView(value: $player.progress, allowTouch: globalSettings.first?.enableInAppSlider ?? true, sliderRange: 0...1)
                        .frame(height: 30)
                    
                    
                    HStack {
                        Text(Duration.seconds(player.playPosition).formatted(.units(width: .narrow)))
                            .monospacedDigit()
                            .font(.caption)
                        Spacer()
                        if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition, maxPlay-5.0 > player.currentEpisode?.metaData?.playPosition ?? 0.0  {
                            Button(action: {
                                Task{
                                    await player.jumpTo(time: maxPlay)
                                }
                            }) {
                                Label {
                                    Text("max play position")
                                        .monospaced()
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "arrow.right.to.line.compact")
                                        .resizable()
                                        .scaledToFit()
                                    
                                }
                                .labelStyle(.titleOnly)
                                
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to max play position")
                            .accessibilityHint("Jumps to the furthest point you have listened to in this episode")
                        }
                        Spacer()
                        Text(Duration.seconds(player.remaining ?? player.currentEpisode?.duration ?? 0.0).formatted(.units(width: .narrow)))

                            .monospacedDigit()
                            .font(.caption)
                    }
                }
                
                
                HStack{
                    
                    Spacer()
                    
                    Button(action:player.skipback){
                        Label {
                            Text("Skip Back")
                        } icon: {
                            Image(systemName: "15.arrow.trianglehead.counterclockwise")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    .accessibilityLabel("Skip back 15 seconds")
                    .accessibilityHint("Moves playback backward by 15 seconds")
                    .accessibilityInputLabels([Text("Skip back"), Text("Back 15 seconds")])
                    
                    Spacer()
                    Button(action: {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .resizable()
                            .scaledToFit()
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    .accessibilityLabel(player.isPlaying ? "Pause playback" : "Start playback")
                    .accessibilityHint(player.isPlaying ? "Pauses the current episode" : "Starts playing the current episode")
                    .accessibilityInputLabels([Text("Play"), Text("Pause"), Text("Playback")])
                    
                    
                    Spacer()
                    Button(action:player.skipforward){
                        Label {
                            Text("Skip Forward")
                        } icon: {
                            Image(systemName: "30.arrow.trianglehead.clockwise")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    .accessibilityLabel("Skip forward 30 seconds")
                    .accessibilityHint("Moves playback forward by 30 seconds")
                    .accessibilityInputLabels([Text("Skip forward"), Text("Forward 30 seconds")])

                    Spacer()
                    Button(action:player.createBookmark){
                        Label {
                            Text("Bookmark")
                        } icon: {
                            Image(systemName: "bookmark.fill")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 30)
                    .accessibilityLabel("Add bookmark")
                    .accessibilityHint("Saves the current playback position as a bookmark")
                    .accessibilityInputLabels([Text("Bookmark"), Text("Add bookmark")])
                    
                }
                .frame(height: 40)
                .tint(.primary)

                
            }
            .padding()
        }
    }
}
