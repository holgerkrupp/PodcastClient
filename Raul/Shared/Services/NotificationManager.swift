//
//  NotificationManager.swift
//  Raul
//
//  Created by Holger Krupp on 20.05.25.
//

import UserNotifications
import Combine
import SwiftUI
import BasicLogger

enum SkipProtectionNotification {
    static let categoryIdentifier = "SKIP_PROTECTION_UNDO"
    static let undoActionIdentifier = "SKIP_PROTECTION_UNDO_ACTION"
    static let requestIdentifier = "skip-protection-undo"
    static let undoIDUserInfoKey = "skipProtectionUndoID"
    static let expiresAtUserInfoKey = "skipProtectionExpiresAt"

    static func registerCategory() {
        let undoAction = UNNotificationAction(
            identifier: undoActionIdentifier,
            title: String(localized: "Undo"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [undoAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

enum NotificationSchedulingError: LocalizedError {
    case denied
    case invalidDate
    case liveNotificationsDisabled

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Notifications are disabled for Raul."
        case .invalidDate:
            return "The live event start time has already passed."
        case .liveNotificationsDisabled:
            return "Live event notifications are turned off in settings."
        }
    }
}

@MainActor
class NotificationPermissionViewModel: ObservableObject {
    @Published var isAuthorized = false

    private let notificationManager = NotificationManager()

    func refreshPermissionStatus() {
        Task {
            let granted = await notificationManager.getPermissionStatus()
            isAuthorized = granted
        }
    }

    func requestPermission() {
        Task {
            let granted = await notificationManager.requestAuthorization()
            isAuthorized = granted
            
        }
    }
}

actor NotificationManager {
    static let shared = NotificationManager()

    private static let liveNotificationPrefix = "podcast-live-"
    private var skipProtectionCleanupTask: Task<Void, Never>?
    
    func requestAuthorizationIfUndetermined() async {
        if await getAuthorizationStatus() == .notDetermined {
            _ = await requestAuthorization()
        }
    }
    

    
    func getPermissionStatus() async -> Bool {
        let authorizationStatus = await isNotificationAuthorized()
        return authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // print("Notification permission error: \(error)")
            return false
        }
    }

    func sendSkipProtectionUndoNotification(
        undoID: UUID,
        episodeTitle: String,
        positionDescription: String,
        expiresAt: Date
    ) async {
        let authorizationStatus = await getAuthorizationStatus()
        let canDeliver: Bool
#if os(macOS)
        canDeliver = authorizationStatus == .authorized
            || authorizationStatus == .provisional
#else
        canDeliver = authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
#endif
        guard canDeliver else {
            return
        }

        await removeSkipProtectionUndoNotification()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Playback moved")
        content.body = String(
            localized: "Undo to return to \(episodeTitle) at \(positionDescription)."
        )
        content.sound = .default
        content.categoryIdentifier = SkipProtectionNotification.categoryIdentifier
        content.threadIdentifier = SkipProtectionNotification.requestIdentifier
        content.userInfo = [
            SkipProtectionNotification.undoIDUserInfoKey: undoID.uuidString,
            SkipProtectionNotification.expiresAtUserInfoKey: expiresAt.timeIntervalSince1970
        ]

        let request = UNNotificationRequest(
            identifier: SkipProtectionNotification.requestIdentifier,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)

        let delay = max(0, expiresAt.timeIntervalSinceNow)
        skipProtectionCleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard Task.isCancelled == false else { return }
            await self?.removeSkipProtectionUndoNotification()
        }
    }

    func removeSkipProtectionUndoNotification() async {
        skipProtectionCleanupTask?.cancel()
        skipProtectionCleanupTask = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [SkipProtectionNotification.requestIdentifier]
        )
        center.removeDeliveredNotifications(
            withIdentifiers: [SkipProtectionNotification.requestIdentifier]
        )
    }
    
    private func getAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func isNotificationAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let authorized = settings.authorizationStatus == .authorized
                continuation.resume(returning: authorized)
            }
        }
    }
    
    



    /// Sends a local notification with optional image attachment.
    func sendNotification(title: String, body: String, imageURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Add image if provided
        if let imageURL = imageURL, let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: imageURL, options: nil) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Send immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                Task{
                   //  await BasicLogger.shared.log("🔕 Failed to schedule notification: \(error)")
                }
            }else{
                Task{
                   //  await BasicLogger.shared.log("🔔 Notification sent successfully")
                }
            }
        }
    }

    func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        date: Date,
        userInfo: [AnyHashable: Any] = [:]
    ) async throws {
        guard date > Date() else {
            throw NotificationSchedulingError.invalidDate
        }

        let status = await getAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            guard await requestAuthorization() else {
                throw NotificationSchedulingError.denied
            }
        case .denied:
            throw NotificationSchedulingError.denied
        @unknown default:
            throw NotificationSchedulingError.denied
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        try await UNUserNotificationCenter.current().add(request)
    }

    func liveNotificationIdentifier(podcastFeed: URL?, podcastTitle: String, liveItemID: String) -> String {
        "\(Self.liveNotificationPrefix)\(podcastFeed?.absoluteString ?? podcastTitle)-\(liveItemID)".stableNotificationIdentifier
    }

    func removePendingLiveNotifications(podcastFeed: URL? = nil) async {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let podcastPrefix = podcastFeed.map {
            "\(Self.liveNotificationPrefix)\($0.absoluteString)-".stableNotificationIdentifier
        }

        let identifiers = requests
            .map(\.identifier)
            .filter { identifier in
                if let podcastPrefix {
                    return identifier.hasPrefix(podcastPrefix)
                }
                return identifier.hasPrefix(Self.liveNotificationPrefix)
            }

        guard identifiers.isEmpty == false else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}


struct NotificationSettingsView: View {
    @StateObject private var viewModel = NotificationPermissionViewModel()
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(spacing: 20) {
            if !viewModel.isAuthorized {
                Toggle(isOn: Binding(
                    get: { viewModel.isAuthorized },
                    set: { newValue in
                        if newValue {
                            viewModel.requestPermission()
                        }
                    }
                )) {
                    Text("Enable Notifications")
                }
            } else {
                Button("Open Notification Settings") {
#if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
#else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        openURL(url)
                    }
#endif
                }
            }
        }
       
        .onAppear {
            viewModel.refreshPermissionStatus()
        }
    }
}

extension String {
    var stableNotificationIdentifier: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return unicodeScalars.map { allowed.contains($0) ? Character($0).description : "-" }.joined()
    }
}

#Preview {
    NotificationSettingsView()
}
