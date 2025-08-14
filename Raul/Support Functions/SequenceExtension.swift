//
//  SequenceExtension.swift
//  PodcastClient
//
//  Created by Holger Krupp on 02.02.24.
//
//  See https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
//

import Foundation

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
}

extension Sequence {
    func uniqued(by keyPaths: [ (Element) -> AnyHashable ]) -> [Element] {
        var seen = Set<KeyArray>()
        return filter { element in
            let keyTuple = keyPaths.map { $0(element) }
            let compositeKey = KeyArray(keyTuple)
            return seen.insert(compositeKey).inserted
        }
    }
}

// Helper wrapper to allow an array of Hashable to be itself Hashable
private struct KeyArray: Hashable {
    let keys: [AnyHashable]
    init(_ keys: [AnyHashable]) {
        self.keys = keys
    }
}

extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()
        
        for element in self {
            try await values.append(transform(element))
        }
        
        return values
    }
    
}

extension Sequence {
    func asyncForEach(
        _ operation: (Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
}

