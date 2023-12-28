//
//  DownloadManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 21.12.23.
//

import Foundation


class Download {
    var asset: Asset
    var dowloadState: DownloadState = .none
    var isDownloading: Bool = false
    var progress: Double = 0.0
    var resumeData: Data?
    var sessionTask: URLSessionDownloadTask?
    
    
    init(asset: Asset) {
        self.asset = asset
    }
}

enum ButtonTitle {
    static let download = "Download"
    static let pause = "Pause"
    static let resume = "Resume"
}

enum DownloadState: Int, CustomStringConvertible {
    case none = 0
    case start
    case pause
    case resume
    case cancel
    case alreadyDownloaded
    
    var isOngoing: Bool {
        return self == .start || self == .resume
    }
    
    var buttonTitle: String {
        switch self {
        case .none:
            return ButtonTitle.download
        case .start, .resume:
            return ButtonTitle.pause
        case .alreadyDownloaded, .cancel:
            return ""
        case .pause:
            return ButtonTitle.resume
        }
    }
    
    var isButtonHide: Bool {
        switch self {
        case .alreadyDownloaded, .cancel:
            return true
        default:
            return false
            
        }
    }
    
    var isHideCancelButton: Bool {
        switch self {
        case .start, .pause, .resume:
            return false
        case .alreadyDownloaded:
            return true
        default:
            return true
        }
    }
    
    var description: String {
        switch self {
        case .start:
            return "Download about start"
        case .resume:
            return "Download will resume"
        case .pause:
            return "Download is paused"
            
        default:
            return ""
        }
    }
    
}

class DownloadManager: NSObject, URLSessionDownloadDelegate{
    
    lazy var downloadsSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier:
                                                                "com.bgSession")
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // here do something after download finished
        print("download of \(session.description) finished")
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Here show the progress of download file
    }

    

}
