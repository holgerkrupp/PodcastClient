import Foundation

enum WatchCellularSupport {
    static var canUseCellularDownloads: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        cellularCapableModelIdentifiers.contains(currentModelIdentifier)
        #endif
    }

    private static let cellularCapableModelIdentifiers: Set<String> = [
        "Watch6,3", "Watch6,4",
        "Watch6,8", "Watch6,9",
        "Watch6,12", "Watch6,13",
        "Watch6,16", "Watch6,17",
        "Watch6,18",
        "Watch7,3", "Watch7,4",
        "Watch7,5",
        "Watch7,10", "Watch7,11",
        "Watch7,12",
        "Watch7,15", "Watch7,16",
        "Watch7,19", "Watch7,20"
    ]

    private static var currentModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)

        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { reboundPointer in
                String(validatingCString: reboundPointer) ?? ""
            }
        }
    }
}
