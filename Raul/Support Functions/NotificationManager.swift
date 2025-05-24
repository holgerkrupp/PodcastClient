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
    
   
    
    func getPermissionStatus() async -> Bool {
        let authorizationStatus = await isNotificationAuthorized()
        return authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("Notification permission error: \(error)")
            return false
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
            if let error = error {
                Task{
                    await BasicLogger.shared.log("🔕 Failed to schedule notification: \(error)")
                }
            }else{
                Task{
                    await BasicLogger.shared.log("🔔 Notification sent successfully")
                }
            }
        }
    }
}


struct NotificationSettingsView: View {
    @StateObject private var viewModel = NotificationPermissionViewModel()

    var body: some View {
        VStack {
            Text(viewModel.isAuthorized ? "✅ Notifications On" : "❌ Notifications Off")

            Button("Request Notifications") {
                viewModel.requestPermission()
            }

            Button("Refresh Status") {
                viewModel.refreshPermissionStatus()
            }
        }
        .onAppear {
            viewModel.refreshPermissionStatus()
        }
    }
}
