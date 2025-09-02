import UIKit

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
}
