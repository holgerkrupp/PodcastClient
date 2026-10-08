import Foundation

/// Round-robin ordering for playlist entries. Group order follows first
/// appearance, and each group's relative order is retained.
enum SmartShuffleOrdering {
    static func interleavedIndices(groupKeys: [String], pinnedIndex: Int? = nil) -> [Int] {
        guard groupKeys.isEmpty == false else { return [] }
        guard let pinnedIndex, groupKeys.indices.contains(pinnedIndex) else {
            return interleave(Array(groupKeys.indices), groupKeys: groupKeys)
        }

        // Keep the current episode in its exact queue slot. Interleaving each
        // side separately also preserves that show's relative order around it.
        let before = interleave(Array(0..<pinnedIndex), groupKeys: groupKeys)
        let after = interleave(Array((pinnedIndex + 1)..<groupKeys.count), groupKeys: groupKeys)
        return before + [pinnedIndex] + after
    }

    private static func interleave(_ indices: [Int], groupKeys: [String]) -> [Int] {
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for index in indices {
            let key = groupKeys[index]
            if groups[key] == nil {
                groups[key] = []
                groupOrder.append(key)
            }
            groups[key, default: []].append(index)
        }

        var result: [Int] = []
        var depth = 0
        while true {
            var appended = false
            for key in groupOrder {
                guard let group = groups[key], group.indices.contains(depth) else { continue }
                result.append(group[depth])
                appended = true
            }
            guard appended else { break }
            depth += 1
        }
        return result
    }
}
