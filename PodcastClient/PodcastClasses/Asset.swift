
//  Asset.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


enum AssetType:Codable{
    case chapter, audio, video, image
}

@Model
class Asset{
    

    
    
    var name: String?
    var desc: String?
    var type: AssetType?
    var link: URL? // the original URL of the asset
    var file: URL? // the local URL of the file if downloaded
 
    init(){}

    
}
