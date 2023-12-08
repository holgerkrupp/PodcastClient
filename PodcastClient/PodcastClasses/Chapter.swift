//  chapter.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


@Model
class Chapter{
    
    var name: String?
    var desc: String?
    var link: URL?
    var image:Asset?
    
    var skip:Bool = false
    
    init(){}

}
