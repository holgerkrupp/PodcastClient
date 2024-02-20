//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct EpisodeView: View {
    

    private let coverSize:CGFloat = 100

    @Environment(\.modelContext) var modelContext

    @State var episode: Episode?
    
    @State var showBookmarks:Bool = false
    @State var showSkips:Bool  = false
    
    
    var body: some View {
        if let episode{
            
            
            
            VStack{
                HStack{
                    
                    if episode.finishedPlaying == true{
                        Image(systemName: "circle.fill")
                    }else{
                        Image(systemName: "circle")
                    }
                    
                    
                    if let imageULR = episode.image{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: coverSize, height: coverSize)
                        
                    }else if let imageULR = episode.podcast?.coverURL{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: coverSize, height: coverSize)
                    }else{
                        Image(systemName: "mic.fill")
                            .scaledToFit()
                            .frame(width: coverSize, height: coverSize)
                    }
                    
                    VStack{
                        Text(episode.pubDate?.formatted() ?? "").font(.caption)
                        
                        if let count = episode.events?.filter({$0.type == .skip}).count, count > 0{
                            Text("\(count) Skips detected")
                        }
                        if let count = episode.events?.filter({$0.type == .bookmark}).count, count > 0{
                            Text("\(count) Bookmarks detected")
                        }
                        
                    }
                }
                EpisodePlayProgressView(episode: episode)
                    .frame(maxWidth: .infinity, maxHeight: 30)
                Spacer()
                EpisodeControlView(episode: episode)
                
                HStack{
                    if let events = episode.events?.filter({ $0.type == .bookmark}).sorted(by: {$0.date > $1.date}), events.count > 0{
                        Button {
                            showBookmarks.toggle()
                        } label: {
                            Label {
                                Text("Show Bookmarks")
                            } icon: {
                                Image(systemName: "bookmark.circle")
                                    .tint(.primary)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .sheet(isPresented: $showBookmarks, content: {
                            
                            SkipAndBookmarkListView(events: events)
                                .presentationDragIndicator(.visible)
                                .presentationBackground(.thinMaterial)
                                
                            
                        })
                    }
                    Spacer()
                    if let events = episode.events?.filter({ $0.type == .skip}).sorted(by: {$0.date > $1.date}), events.count > 0{
                        Button {
                            showSkips.toggle()
                        } label: {
                            Label {
                                Text("Show Skips")
                            } icon: {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .tint(.primary)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .sheet(isPresented: $showSkips, content: {
                            
                            SkipAndBookmarkListView(events: events)
                                .presentationDragIndicator(.visible)
                                .presentationBackground(.thinMaterial)
                       
                            
                        })
                    }
                }

                
                
                let desciption = episode.content ?? episode.desc ?? ""
                
                HTMLView(htmlString: desciption)
                    .lineLimit(nil)
                    .selectionDisabled(false)
                    .foregroundColor(.primary)
                    .font(.body)
                    
                /*
                 Text(desciption)
                 .lineLimit(nil)
                 .selectionDisabled(false)
                 .foregroundColor(.primary)
                 .font(.body)
                 */
                
            }

          
            /*
            
             .onAppear{
             _ = episode.UpdateisAvailableLocally()
             }
             
            if let chapters = episode.chapters{
                ChapterListView(chapters: chapters)
            }
            */
            
        }
        
        //    .listStyle(.plain)
        //   .navigationTitle(Text(episode.title ?? ""))
        
        
        else{
            Text("error loading episode")
        }
    }
    
    
    
}

struct EpisodeMiniView: View {
    
    @Environment(\.modelContext) var modelContext

    // @Environment(Episode.self) private var episode
    
    var formatStyle = Date.RelativeFormatStyle()
 
   // var model: EpisodeListItemModel
   @State  var episode: Episode
    
    
    var body: some View {
        NavigationLink {
            
            EpisodeView(episode: episode)
                .modelContext(modelContext)
           
        }label:{
            VStack{
                HStack{
                    VStack{
                        Spacer()
                        if episode.finishedPlaying == true{
                            Image(systemName: "checkmark.circle")
                        }else{
                            Image(systemName: "circle")
                        }
                        Spacer()
                        EpisodeStatusIcon(episode: episode)
                        Spacer()
                        
                        if episode.transcriptData != nil{
                           
                                    Image(systemName: "captions.bubble")
                                      
                            }
                        
                    }
                    
                    if let data = episode.cover{
                        ImageWithData(data)
                            .scaledToFit()
                            .frame(width: 50, height: 50)

                    }else if let imageULR = episode.image{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                        
                    }else if let imageULR = episode.podcast?.coverURL{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                    }else{
                        Image(systemName: "mic.fill")
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                    }
                    
                    VStack(alignment: .leading){
                        Spacer()
                        Text(episode.title ?? "")
                        Spacer()
                        HStack{
                            Text(episode.pubDate?.formatted(formatStyle) ?? "--")
                            Spacer()
                            /*
                            Text(episode.duration?.secondsToHoursMinutesSeconds ?? "")
                                .monospacedDigit()
                        */
                             }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                if let desc = episode.desc{
                    Spacer()
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
              //  if episode.playPosition > 0.0{
                    EpisodePlayProgressView(episode: episode)
                        .frame(maxWidth: .infinity, maxHeight: 30)
           //     }
                
            }
            
        }
        /*
        .contextMenu {
            Button {
                    model.episode.playNow()
            } label: {
                Label("Play now", systemImage: "play")
            }
            Button {
                PlaylistManager.shared.playnext.add(episode: model.episode, to: .front)

                
            } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                PlaylistManager.shared.playnext.add(episode: model.episode, to: .end)
                
            } label: {
                Label("Play last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
         */
    }
}


struct EpisodeMetaDataView: View{
    
    var episode: Episode
    
    var body: some View {
        VStack{
            HStack{
                Text("Download?")
            }
            
        }
    }
}



@Observable
class EpisodeListItemModel {
    var episode: Episode
    
    init(episode: Episode) {
        self.episode = episode
    }
}



struct EpisodeStatusIcon:View{
    @State var episode:Episode

    
    
    
    var body: some View {
        if episode.isAvailableLocally ?? false{
            Image(systemName: "externaldrive.badge.checkmark")
                .scaledToFit()
                .frame(width: 10, height: 10)
        }else if episode.downloadStatus.isDownloading{
            ProgressView(value: episode.downloadStatus.downloadProgress)
                .progressViewStyle(.circular)
                .frame(width: 10, height: 10)
 
        }else{
            Image(systemName: "cloud")
                .scaledToFit()
                .frame(width: 10, height: 10)
        }
    }
}


struct EpisodePlayProgressView:View{
   
    @State var episode:Episode

    var body: some View {
            HStack{
                ProgressView(value: episode.progress, total: episode.duration ?? 500)
                        .progressViewStyle(.linear)
                if let duration = episode.duration {
                    
                    if (duration - (episode.playPosition ?? 0)) > 0.9{
                        
                        Text("\((duration - (episode.playPosition ?? 0)).secondsToHoursMinutesSeconds ?? "")")
                            .monospacedDigit()
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                    }else{
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.secondary)
                    }
                }
        }
    }
    
}


