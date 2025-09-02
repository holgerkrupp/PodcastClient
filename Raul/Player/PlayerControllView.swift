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

    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
    @State var showSettings: Bool = false
    @State private var showClipExport = false
    
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" } ) var globalSettings: [PodcastSettings]
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack {
                
                HStack {
                    AirPlayButtonView()
                        .tint(.primary)
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        
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
               
                    
                    
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showSpeedSetting, content: {
                    VStack{
                        /*
                         Text("Adjust Sleeptimer")
                         Toggle(isOn: $player.sleeptimer.activated) {
                         Text("Activate Sleeptimer")
                         }
                         Stepper(value: $player.sleeptimer.minutes, in: 1...60, step: 1) {
                         Text(player.sleeptimer.secondsLeft?.secondsToHoursMinutesSeconds ?? "00:00")
                         }
                         .disabled(!player.sleeptimer.activated)
                         */
                        
                        
                        Text("Adjust Playback Speed")
                        Stepper(value: $player.playbackRate, in: 0.1...3.0, step: 0.1) {
                        
                            Text(String(format: "%.1fx", player.playbackRate))
                        }
                        
                        Spacer()
                        Button("Show all Settings") {
                            showSettings = true
                        }
                        .buttonStyle(.glass)
                        
                    }.padding()
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                        .presentationDetents([.fraction(0.3)])
                        .sheet(isPresented: $showSettings) {
                           
                            if let podcast = player.currentEpisode?.podcast {
                                PodcastSettingsView(podcast: podcast, modelContainer: context.container)
                                        .presentationBackground(.ultraThinMaterial)
                            }else{
                                PodcastSettingsView(podcast: nil, modelContainer: context.container)
                                        .presentationBackground(.ultraThinMaterial)
                            }
                            
                        
                    }
                    
                })
                
                ZStack() {
                    Color.clear
                    
                    CoverImageView(episode: episode, timecode: player.currentChapter?.start)
                        .id(episode.id)
                        .scaledToFit()
                    /*
                    Group{
                        if let chapterImage = player.currentChapter?.imageData {
                            ImageWithData(chapterImage)
                                .id(player.currentChapter?.id ?? UUID())
                                .scaledToFit()
                        }else{
                            EpisodeCoverView(episode: episode)
                                .id(episode.id)
                            
                                .scaledToFit()
                        }
                    }
                     */
                    .frame(maxWidth: .infinity)
                    
                    .overlay(alignment: .bottom) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines,
                           player.playPosition.isNormal, showTranscripts {
                            
                           // let decoder = TranscriptDecoder(transcriptFileContent)
                            
                            TranscriptView(transcriptLines: transcriptLines.sorted(by: { $0.startTime < $1.startTime }), currentTime: $player.playPosition)
                            
                            
                                .background(.ultraThinMaterial)
                            
                        }
                    }
                    .sheet(isPresented: $showFullTranscripts) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines {
                            TranscriptListView(transcriptLines: transcriptLines)
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                    }
                    
                }
                
                if let transcripts = player.currentEpisode?.transcriptLines, transcripts.count > 0 {
                    HStack {
                        if showTranscripts{
                            Image("custom.quote.bubble.slash")
                                .onTapGesture(perform: {
                                    showTranscripts.toggle()
                                })
                        }else{
                            Image(systemName: "quote.bubble")
                                .onTapGesture(perform: {
                                    showTranscripts.toggle()
                                })
                        }
                        Spacer()
                        Image("custom.quote.bubble.rectangle.portrait")
                            .onTapGesture(perform: {
                                showFullTranscripts.toggle()
                            })
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
                        if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition, maxPlay > player.currentEpisode?.metaData?.playPosition ?? 0.0  {
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
                    
                    
                    Spacer()
                    Button(action:player.skipforward){
                        Label {
                            Text("Skip Back")
                        } icon: {
                            Image(systemName: "30.arrow.trianglehead.clockwise")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    Spacer()
                    Button(action: {
                        showClipExport = true
                    }) {
                        Image(systemName: "scissors")
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 30)
                    .help("Share audio clip")
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
                    
                }
                .frame(height: 40)
                .tint(.primary)
                .sheet(isPresented: $showClipExport) {
                    // TODO: coverImage loading should ideally not be async in the sheet
                    
                    if let episode = player.currentEpisode, let audioURL = episode.localFile ?? episode.url {
                        AudioClipExportView(
                            audioURL: audioURL,
                            coverImageURL: episode.imageURL,
                            fallbackCoverImageURL: episode.podcast?.imageURL,
                            playPosition: player.playPosition,
                            duration: episode.duration ?? 60
                        )
                    } else {
                        EmptyView()
                    }
                }
                
            }
            .padding()
        }
    }
}

