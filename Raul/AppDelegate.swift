import UIKit
import BackgroundTasks
import BasicLogger

class AppDelegate: NSObject, UIApplicationDelegate {
    // This is where the system gives us a completion handler
    // when background URLSession events are delivered
    var backgroundSessionCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Save for later, DownloadManager will call this in urlSessionDidFinishEvents
        backgroundSessionCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrashBreadcrumbs.shared.record("app_delegate_did_finish_launching")
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAutomaticTranscriptionProcessing(task: processingTask)
        }

        return true
    }

    static func scheduleAutomaticTranscriptionProcessingIfNeeded() async {
        let settingsActor = PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container)
        let automaticTranscriptionsEnabled = await settingsActor.getAutomaticOnDeviceTranscriptionsEnabled()
        let requiresCharging = await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging()

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier)

        guard automaticTranscriptionsEnabled, requiresCharging else {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_not_scheduled",
                details: "enabled=\(automaticTranscriptionsEnabled),requires_charging=\(requiresCharging)"
            )
            return
        }

        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_schedule_requested")
        BasicLogger.shared.log("schedule automaticTranscriptionProcessing")
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.automaticTranscriptionInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("automatic_transcription_background_task_scheduled")
        } catch {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_schedule_failed",
                details: error.localizedDescription
            )
            BasicLogger.shared.log(error.localizedDescription)
        }
    }

    private func handleAutomaticTranscriptionProcessing(task: BGProcessingTask) {
        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_started")
        task.expirationHandler = {
            CrashBreadcrumbs.shared.record("automatic_transcription_background_task_expired")
            BasicLogger.shared.log("automatic transcription background task expired")
        }

        Task {
            await Self.scheduleAutomaticTranscriptionProcessingIfNeeded()
            let didProcess = await TranscriptionManager.shared.runAutomaticTranscriptionsFromUpNextUntilIdle()
            CrashBreadcrumbs.shared.record("automatic_transcription_background_task_completed", details: "did_process=\(didProcess)")
            task.setTaskCompleted(success: didProcess)
        }
    }
}
