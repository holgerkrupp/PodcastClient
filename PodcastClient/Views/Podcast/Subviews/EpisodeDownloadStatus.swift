//
//  EpisodeDownloadStatus.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.01.24.
//

import Foundation

@Observable
class EpisodeDownloadStatus{
     var isDownloading: Bool = false
    private(set) var currentBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    var downloadProgress: Double {
        guard totalBytes > 0 else { return 0.0 }
        
        return Double(currentBytes) / Double(totalBytes)
    }
    
    
    
    func update(currentBytes: Int64, totalBytes: Int64) {
        print(Double(currentBytes) / Double(totalBytes))
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }
    

}
