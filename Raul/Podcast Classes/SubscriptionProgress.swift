//
//  SubscriptionProgress.swift
//  Raul
//
//  Created by Codex on 25.03.26.
//

import Foundation

struct SubscriptionProgressUpdate: Sendable {
    let fractionCompleted: Double
    let message: String

    init(_ fractionCompleted: Double, _ message: String) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.message = message
    }
}

typealias SubscriptionProgressHandler = @Sendable (SubscriptionProgressUpdate) async -> Void
