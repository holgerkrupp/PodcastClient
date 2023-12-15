
//  Asset.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData
import AVFoundation


enum AssetType:String, Codable{
    case audio, video, image, unknown
}

@Model
class Asset{
    

    
    
    var title: String?
    var desc: String?
    var type: AssetType?
    var link: URL? // the original URL of the asset
    var file: URL? // the local URL of the file if downloaded
    var length: Int?
    
    var avAsset:AVAsset? {
        if let url = file ?? link{
           return AVAsset(url: url)
        }else{
            return nil
        }
    }
    
 
    init(){}

    init(details: [String: Any]) {
        title = details["title"] as? String
        
        desc = details["description"] as? String
        
        link = URL(string: details["url"] as? String ?? "")
        
        length = Int(details["length"] as? String ?? "")
        
        switch details["type"] as? String{
        case "audio/mpeg":
            type = AssetType.audio
        case .none:
            type = AssetType.unknown
        case .some(_):
            type = AssetType.unknown
        }
        
        
        
        
        
    }
    
}
