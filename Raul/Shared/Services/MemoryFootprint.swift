import Foundation

/// Lightweight process memory telemetry used to prove that the slice-based
/// store-split migration keeps a bounded footprint across slices.
///
/// `phys_footprint` is the same metric the OS uses for the per-process jetsam
/// limit, so comparing the value before and after each slice tells us whether a
/// slice leaked retained objects (e.g. a faulted SwiftData relationship graph).
enum MemoryFootprint {
    /// Current physical memory footprint of the process, in bytes.
    /// Returns `0` if the kernel call fails.
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Human readable rendering of a byte count (e.g. "128 MB").
    static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bitPattern: bytes),
            countStyle: .memory
        )
    }

    /// Signed human readable delta between two footprints (e.g. "+12 MB").
    static func formattedDelta(before: UInt64, after: UInt64) -> String {
        let delta = Int64(bitPattern: after) - Int64(bitPattern: before)
        let sign = delta >= 0 ? "+" : "-"
        let magnitude = ByteCountFormatter.string(
            fromByteCount: abs(delta),
            countStyle: .memory
        )
        return "\(sign)\(magnitude)"
    }
}
