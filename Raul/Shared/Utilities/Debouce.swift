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

    func perform(after delay: TimeInterval = 0.3, block: @escaping () -> Void) {
        workItem?.cancel()
        let newItem = DispatchWorkItem(block: block)
        workItem = newItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newItem)
    }
}
