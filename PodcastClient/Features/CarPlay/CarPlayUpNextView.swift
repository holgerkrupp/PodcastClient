//
//  CarPlayUpNextView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 20.02.24.
//

import SwiftUI
import SwiftData
import CarPlay

let item = CPListItem(text: "My title", detailText: "My subtitle")

item.listItemHandler = { item, completion, [weak self] in
    // Start playback asynchronously…
    self.interfaceController.pushTemplate(CPNowPlayingTemplate.shared(), animated: true)
    completion()
}
let section = CPListSection(items: [item])
let listTemplate = CPListTemplate(title: "Albums", sections: [section])
self.interfaceController.pushTemplate(listTemplate, animated: true)
