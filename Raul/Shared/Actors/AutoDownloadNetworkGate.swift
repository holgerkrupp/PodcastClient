//
//  AutoDownloadNetworkGate.swift
//  Raul
//

import Foundation
import Network

/// Shared answer to "may an automatic download start on the current network?".
///
/// The per-podcast policy and the per-playlist policy gate on the same user
/// preference, so the path check lives in one place instead of once per policy.
enum AutoDownloadNetworkGate {
    static func canScheduleDownloads(for networkMode: AutoDownloadNetworkMode) async -> Bool {
        switch networkMode {
        case .wifiAndCellular:
            return true
        case .wifiOnly:
            return await isOnWiFi()
        }
    }

    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "AutoDownloadNetworkMonitor")
            // `cancel()` does not retract path updates already queued behind
            // this one, and resuming a continuation twice traps.
            let state = ResumeState()

            monitor.pathUpdateHandler = { path in
                let isConnected = path.status == .satisfied
                let isWiFiLikeConnection = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                monitor.cancel()
                guard state.claim() else { return }
                continuation.resume(returning: isConnected && isWiFiLikeConnection)
            }

            monitor.start(queue: queue)
        }
    }

    /// Only ever touched from the monitor's own serial queue.
    private final class ResumeState: @unchecked Sendable {
        private var hasResumed = false

        func claim() -> Bool {
            guard hasResumed == false else { return false }
            hasResumed = true
            return true
        }
    }
}
