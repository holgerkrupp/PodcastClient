import SwiftUI

struct SharedEpisodeRecovery: Identifiable {
    let id = UUID()
    let url: URL
    let message: String
    let suggestedSearch: String?
}

enum SharedEpisodeRecoveryAction {
    case search
    case retry
    case openBrowser
    case dismiss
}

struct SharedEpisodeRecoveryView: View {
    let recovery: SharedEpisodeRecovery
    let action: (SharedEpisodeRecoveryAction) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Shared page") {
                Text(recovery.url.host() ?? recovery.url.redactedPodcastURLString)
                        .font(.headline)
                    Text(recovery.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Search Podcasts") { action(.search) }
                    Button("Try Again") { action(.retry) }
                    if let browserURL = browserURL {
                        Link("Open in Browser", destination: browserURL)
                    }
                    Button("Dismiss", role: .cancel) { action(.dismiss) }
                }
            }
            .navigationTitle("Couldn’t Add Episode")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { action(.dismiss) }
                }
            }
        }
    }

    private var browserURL: URL? {
        switch recovery.url.scheme?.lowercased() {
        case "feed", "rss": return nil
        default: return recovery.url.isFileURL ? nil : recovery.url
        }
    }
}
