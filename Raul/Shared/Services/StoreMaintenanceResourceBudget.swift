import Darwin
import Foundation

struct ProcessCPUSample: Equatable, Sendable {
    let uptime: TimeInterval
    let cpuTime: TimeInterval
}

protocol ProcessCPUTimeSource: Sendable {
    func sample() -> ProcessCPUSample
}

struct SystemProcessCPUTimeSource: ProcessCPUTimeSource {
    func sample() -> ProcessCPUSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = TimeInterval(usage.ru_utime.tv_sec)
            + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec)
            + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return ProcessCPUSample(
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuTime: user + system
        )
    }
}

struct StoreMaintenanceCPUThresholds: Equatable, Sendable {
    let shortWindow: TimeInterval
    let shortDutyCycle: Double
    let mediumWindow: TimeInterval
    let mediumDutyCycle: Double
    let longWindow: TimeInterval
    let longDutyCycle: Double
    let cooldown: TimeInterval

    static let conservative = StoreMaintenanceCPUThresholds(
        shortWindow: 15,
        shortDutyCycle: 0.75,
        mediumWindow: 60,
        mediumDutyCycle: 0.70,
        longWindow: 180,
        longDutyCycle: 0.55,
        cooldown: 30
    )
}

/// Process-wide admission control for voluntary database maintenance. CPU is
/// measured with getrusage (user + system time), so CloudKit mirroring work in
/// Core Data is included even after an app-owned batch has yielded.
final class StoreMaintenanceResourceBudget: @unchecked Sendable {
    static let shared = StoreMaintenanceResourceBudget()

    private let lock = NSLock()
    private let source: any ProcessCPUTimeSource
    private let thresholds: StoreMaintenanceCPUThresholds
    private var samples: [ProcessCPUSample] = []
    private var activeLeaseID: UUID?
    private var activeOperation: String?
    private var cooldownUntil: TimeInterval = 0

    init(
        source: any ProcessCPUTimeSource = SystemProcessCPUTimeSource(),
        thresholds: StoreMaintenanceCPUThresholds = .conservative
    ) {
        self.source = source
        self.thresholds = thresholds
        self.samples = [source.sample()]
    }

    func acquire(
        operation: String,
        playbackActive: Bool,
        cloudKitExportActive: Bool
    ) -> StoreMaintenancePermit? {
        lock.lock()
        defer { lock.unlock() }
        if activeLeaseID != nil {
            recordYield(operation: operation, reason: "maintenance_busy")
            return nil
        }
        let reason = denialReason(
            playbackActive: playbackActive,
            cloudKitExportActive: cloudKitExportActive
        )
        guard reason == nil else {
            recordYield(operation: operation, reason: reason!)
            return nil
        }
        let id = UUID()
        activeLeaseID = id
        activeOperation = operation
        return StoreMaintenancePermit(id: id, operation: operation, owner: self)
    }

    fileprivate func yieldReason(
        leaseID: UUID,
        playbackActive: Bool,
        cloudKitExportActive: Bool
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeaseID == leaseID else { return "permit_invalidated" }
        let reason = denialReason(
            playbackActive: playbackActive,
            cloudKitExportActive: cloudKitExportActive
        )
        if let reason {
            recordYield(operation: activeOperation ?? "unknown", reason: reason)
        }
        return reason
    }

    fileprivate func release(leaseID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeaseID == leaseID else { return }
        activeLeaseID = nil
        activeOperation = nil
    }

    private func denialReason(
        playbackActive: Bool,
        cloudKitExportActive: Bool
    ) -> String? {
        if playbackActive { return "playback" }
        if cloudKitExportActive { return "export_busy" }
        let sample = source.sample()
        append(sample)
        if sample.uptime < cooldownUntil { return "cpu_cooldown" }
        if dutyCycle(window: thresholds.shortWindow) >= thresholds.shortDutyCycle
            || dutyCycle(window: thresholds.mediumWindow) >= thresholds.mediumDutyCycle
            || dutyCycle(window: thresholds.longWindow) >= thresholds.longDutyCycle {
            cooldownUntil = sample.uptime + thresholds.cooldown
            return "cpu_budget"
        }
        return nil
    }

    private func append(_ sample: ProcessCPUSample) {
        if let last = samples.last, sample.uptime <= last.uptime { return }
        samples.append(sample)
        let cutoff = sample.uptime - thresholds.longWindow
        samples.removeAll { $0.uptime < cutoff }
    }

    private func dutyCycle(window: TimeInterval) -> Double {
        guard let newest = samples.last else { return 0 }
        let cutoff = newest.uptime - window
        guard let baseline = samples.last(where: { $0.uptime <= cutoff })
                ?? samples.first(where: { $0.uptime < newest.uptime }) else {
            return 0
        }
        let elapsed = newest.uptime - baseline.uptime
        guard elapsed >= min(5, window / 2), elapsed > 0 else { return 0 }
        return max(0, newest.cpuTime - baseline.cpuTime) / elapsed
    }

    private func recordYield(operation: String, reason: String) {
        let sample = source.sample()
        append(sample)
        let shortDuty = dutyCycle(window: thresholds.shortWindow)
        let mediumDuty = dutyCycle(window: thresholds.mediumWindow)
        let longDuty = dutyCycle(window: thresholds.longWindow)
        CrashBreadcrumbs.shared.record(
            "store_maintenance_yielded",
            details: "operation=\(operation),reason=\(reason),process_cpu_seconds=\(String(format: "%.2f", sample.cpuTime)),cpu_duty_15s=\(String(format: "%.2f", shortDuty)),cpu_duty_60s=\(String(format: "%.2f", mediumDuty)),cpu_duty_180s=\(String(format: "%.2f", longDuty))"
        )
    }
}

final class StoreMaintenancePermit: @unchecked Sendable {
    private let id: UUID
    let operation: String
    private let owner: StoreMaintenanceResourceBudget
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(id: UUID, operation: String, owner: StoreMaintenanceResourceBudget) {
        self.id = id
        self.operation = operation
        self.owner = owner
    }

    func yieldReason(playbackActive: Bool, cloudKitExportActive: Bool) -> String? {
        owner.yieldReason(
            leaseID: id,
            playbackActive: playbackActive,
            cloudKitExportActive: cloudKitExportActive
        )
    }

    func release() {
        lock.lock()
        guard isReleased == false else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        owner.release(leaseID: id)
    }

    deinit { release() }
}
