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

enum NotificationSchedulingError: LocalizedError {
    case denied
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Notifications are disabled for Raul."
        case .invalidDate:
            return "The live event start time has already passed."
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
}


struct NotificationSettingsView: View {
    @StateObject private var viewModel = NotificationPermissionViewModel()
    
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
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
       
        .onAppear {
            viewModel.refreshPermissionStatus()
        }
    }
}

#Preview {
    NotificationSettingsView()
}
