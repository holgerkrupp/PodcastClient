import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A general, thread-safe gate that lets heavy background work cooperate with
/// the system and the user.
///
/// Long-running maintenance work (e.g. the store-split user-state importer)
/// calls ``waitUntilIdle()`` between units of work. The gate reports the system
/// as *busy* — and asks callers to pause — when any of the following hold:
///
/// - the device is under thermal pressure (`.serious` / `.critical`), which is
///   our proxy for sustained CPU load,
/// - the OS has signalled memory pressure (`.warning` / `.critical`),
/// - the app is in the foreground and the user interacted very recently.
///
/// When none of these hold (the device is idle, or the app is backgrounded) the
/// gate opens and callers run at full speed. The intent is "do as much work as
/// possible while idle, but never compete with the user for the main thread."
///
/// The conditions are deliberately generic rather than tied to any particular
/// screen, so new heavy work can adopt the same gate without bespoke rules.
final class SystemPressureGate: @unchecked Sendable {
    static let shared = SystemPressureGate()

    private let lock = NSLock()
    private var memoryPressured = false
    private var sceneActive = true
    private var lastInteraction = Date.distantPast
    private var memorySource: DispatchSourceMemoryPressure?

    /// How long after the last user interaction we keep deferring heavy work
    /// while the app is in the foreground. Short enough that work resumes during
    /// natural pauses, long enough to keep navigation and scrolling smooth.
    private let foregroundQuietWindow: TimeInterval = 2.0

    /// Polling interval used while waiting for an idle window.
    private let pollInterval: Duration = .milliseconds(400)

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let pressured = event.contains(.warning) || event.contains(.critical)
            self.lock.lock()
            self.memoryPressured = pressured
            self.lock.unlock()
        }
        source.activate()
        memorySource = source
    }

    // MARK: - Inputs

    /// Records that the user just interacted (navigation, scrolling, tapping).
    /// While the app is foreground-active this defers heavy work for a short
    /// quiet window so the UI stays responsive.
    func noteUserInteraction() {
        let now = Date()
        lock.lock()
        lastInteraction = now
        lock.unlock()
    }

    /// Updates whether the app's scene is foreground-active. When backgrounded,
    /// user-interaction deferral is lifted so maintenance work can run freely
    /// (still subject to thermal and memory pressure).
    func setSceneActive(_ active: Bool) {
        lock.lock()
        sceneActive = active
        if active {
            // Becoming active counts as interaction so we don't immediately
            // slam the main thread during the launch/foreground transition.
            lastInteraction = Date()
        }
        lock.unlock()
    }

    // MARK: - Queries

    /// Whether heavy work should back off right now.
    var isUnderPressure: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        if memoryPressured {
            return true
        }
        if sceneActive, Date().timeIntervalSince(lastInteraction) < foregroundQuietWindow {
            return true
        }
        return false
    }

    /// Cooperatively waits until it is a good time to do heavy work. Returns
    /// immediately if the calling task is cancelled, so it never extends a
    /// shutdown. Safe to call from any actor/task.
    func waitUntilIdle() async {
        while isUnderPressure {
            if Task.isCancelled { return }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
