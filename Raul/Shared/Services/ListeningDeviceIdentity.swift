import Foundation

struct ListeningDeviceIdentity: Sendable, Equatable {
    static let legacySharedID = "__legacy_shared__"

    let id: String
    let displayName: String

    static func current(defaults: UserDefaults = .standard) -> ListeningDeviceIdentity {
        let idKey = "listeningDevice.installationID"
        let nameKey = "listeningDevice.displayName"

        let id: String
        if let existing = defaults.string(forKey: idKey), existing.isEmpty == false {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
        }

        let displayName = defaults.string(forKey: nameKey)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "This device"

        return ListeningDeviceIdentity(id: id, displayName: displayName)
    }
}
