//
//  Debouce.swift
//  Raul
//
//  Created by Holger Krupp on 31.05.25.
//

import Foundation
@MainActor
class Debounce {
    static let shared = Debounce()
    private init() {}
    
    private var workItem: DispatchWorkItem?
    private var keyedWorkItems: [String: DispatchWorkItem] = [:]

    func perform(after delay: TimeInterval = 0.3, block: @escaping () -> Void) {
        workItem?.cancel()
        let newItem = DispatchWorkItem(block: block)
        workItem = newItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newItem)
    }

    func perform(key: String, after delay: TimeInterval = 0.3, block: @escaping () -> Void) {
        keyedWorkItems[key]?.cancel()
        let newItem = DispatchWorkItem { [weak self] in
            block()
            self?.keyedWorkItems[key] = nil
        }
        keyedWorkItems[key] = newItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newItem)
    }
}
