import Combine
import Foundation

/// A warning latch, not a retry ledger or evidence of synchronization.
/// The durable local source remains the recovery source when enqueue fails.
@MainActor
final class PortableWriteFailureMonitor: ObservableObject {
    static let shared = PortableWriteFailureMonitor()
    private static let key = "portableWriteRecoveryWarning"
    private let defaults: UserDefaults
    @Published private(set) var needsRecovery: Bool

    init(defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard) {
        self.defaults = defaults
        needsRecovery = defaults.bool(forKey: Self.key)
    }

    func reportFailure() {
        defaults.set(true, forKey: Self.key)
        needsRecovery = true
    }

    func refresh() {
        if defaults.bool(forKey: Self.key) { needsRecovery = true }
    }
}
