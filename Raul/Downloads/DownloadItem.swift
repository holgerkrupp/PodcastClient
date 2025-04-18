//
//  DownloadItem.swift
//  Raul
//
//  Created by Holger Krupp on 17.04.25.
//


import Foundation
import SwiftUI
import SwiftData

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    
    var episodeID: PersistentIdentifier?
    
    @Published var isFinished: Bool = false

    @Published var isDownloading = false
    @Published var progress: Double = 0.0
    @Published var totalBytes: Int64?
    @Published var downloadedBytes: Int64 = 0

    init(url: URL, episodeID: PersistentIdentifier? = nil) {
        self.url = url
        self.episodeID = episodeID
        
    }

    func update(bytesWritten: Int64, totalBytes: Int64) {
        
        self.downloadedBytes = bytesWritten
        self.totalBytes = totalBytes
        self.progress = totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
        
    }
    
    func setDownloading(_ downloading: Bool) {
        self.isDownloading = downloading
    }
}
