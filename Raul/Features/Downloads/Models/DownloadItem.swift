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

    @Published var isFinished: Bool = false

    @Published var isDownloading = false
    @Published var isPaused = false
    @Published var progress: Double = 0.0
    @Published var totalBytes: Int64?
    @Published var downloadedBytes: Int64 = 0
    @Published var errorMessage: String?
    @Published var isStalled = false

    init(url: URL) {
        // print("create DownloadItem \(url)")
        self.url = url
    }

    func update(bytesWritten: Int64, totalBytes: Int64) {
        self.downloadedBytes = max(downloadedBytes, bytesWritten)
        self.totalBytes = totalBytes > 0 ? totalBytes : nil
        self.progress = totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0
    }
    
    func setDownloading(_ downloading: Bool) {
        self.isDownloading = downloading
    }
}
