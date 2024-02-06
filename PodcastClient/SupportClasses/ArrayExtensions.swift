//
//  ArrayExtensions.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.02.24.
//

import Foundation

extension Array where Element: Hashable {
    func difference(from other: [Element]) -> [Element] {
        let thisSet = Set(self)
        let otherSet = Set(other)
        return Array(thisSet.symmetricDifference(otherSet))
    }
}
