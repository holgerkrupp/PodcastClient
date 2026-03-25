import SwiftUI

@MainActor
final class IncomingPodcastSubscriptionController: ObservableObject {
    enum State {
        case idle
        case loading(URL)
        case resolved(PodcastFeed)
        case failed(URL, String)
    }

    @Published var isPresented = false
    @Published private(set) var state: State = .idle

    private var requestID = UUID()

    static func canHandle(_ url: URL) -> Bool {
        PodcastFeedResolver.canResolve(url)
    }

    func handleIncomingURL(_ url: URL) {
        let nextRequestID = UUID()
        requestID = nextRequestID
        isPresented = true
        state = .loading(url)

        Task {
            do {
                let resolution = try await PodcastFeedResolver.resolve(url: url)

                await MainActor.run {
                    guard self.requestID == nextRequestID else { return }

                    switch resolution {
                    case .podcast(let podcastFeed):
                        self.state = .resolved(podcastFeed)
                    case .requiresBasicAuth:
                        self.state = .failed(url, PodcastFeedResolverError.authenticationRequired(url).localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.requestID == nextRequestID else { return }
                    self.state = .failed(url, error.localizedDescription)
                }
            }
        }
    }

    func dismiss() {
        requestID = UUID()
        isPresented = false
        state = .idle
    }
}

struct IncomingPodcastSubscriptionView: View {
    @ObservedObject var controller: IncomingPodcastSubscriptionController
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            Group {
                switch controller.state {
                case .idle:
                    ContentUnavailableView("No Podcast", systemImage: "dot.radiowaves.left.and.right")
                case .loading(let url):
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(url.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                case .resolved(let podcastFeed):
                    List {
                        SubscribeToPodcastView(newPodcastFeed: podcastFeed)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .listStyle(.plain)
                case .failed(let url, let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could Not Open Podcast")
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let browserURL = browserCompatibleURL(from: url) {
                            Link("Open in Browser", destination: browserURL)
                                .buttonStyle(.glass(.clear))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .navigationTitle("Subscribe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        controller.dismiss()
                    }
                }
            }
        }
    }

    private func browserCompatibleURL(from url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "feed", "pcast", "itpc", "rss":
            return nil
        default:
            return url.isFileURL ? nil : url
        }
    }
}
