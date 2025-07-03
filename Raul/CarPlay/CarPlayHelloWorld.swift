//
//  CarPlayHelloWorldTemplate.swift
//  CPHelloWorld
//
//  Created by Paul Wilkinson on 16/5/2023.
//

import Foundation
import CarPlay
@MainActor
class CarPlayHelloWorld {
    var template: CPListTemplate {
        return CPListTemplate(title: "Hello world", sections: [self.section])
    }
    
    var items: [CPListItem] {
        return [CPListItem(text:"Hello world", detailText: "The world of CarPlay", image: UIImage(systemName: "globe"))]
    }
    
    private var section: CPListSection {
        return CPListSection(items: items)
    }
}
