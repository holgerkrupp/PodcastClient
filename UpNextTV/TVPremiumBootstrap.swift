import CloudKit
import Foundation
import SwiftUI

private final class TVUnavailableCredentialStore: PodcastCredentialStore, @unchecked Sendable {
    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        throw PodcastCredentialStoreError.unavailable
    }

    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential? {
        throw PodcastCredentialStoreError.unavailable
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        throw PodcastCredentialStoreError.unavailable
    }
}

private struct TVSubscriptionManifest: Decodable {
    let entries: [TVSubscriptionManifestEntry]
}

private struct TVSubscriptionManifestEntry: Decodable {
    let feedURL: String
    let accessProfileID: String?
    let accessKindRawValue: String?
    let accessProviderID: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case feedURL
        case accessProfileID
        case accessKindRawValue
        case accessProviderID
        case title
    }
}

enum TVPremiumBootstrapItemState: Equatable, Sendable {
    case ready
    case credentialsRequired(profileID: String)

    var title: String {
        switch self {
        case .ready:
            "Ready on this Apple TV"
        case .credentialsRequired:
            "Credentials required on this Apple TV"
        }
    }
}

struct TVPremiumBootstrapItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let host: String
    let state: TVPremiumBootstrapItemState
}

enum TVPremiumBootstrapState: Equatable, Sendable {
    case loading
    case noSubscriptions
    case loaded([TVPremiumBootstrapItem])
    case unavailable(String)
}

@MainActor
final class TVPremiumBootstrapStore: ObservableObject {
    static let manifestKey = "subscriptionManifest.v1"
    static let cloudContainerIdentifier = "iCloud.de.holgerkrupp.PodcastClient"

    @Published private(set) var state: TVPremiumBootstrapState = .loading

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        let scopeID = await Self.currentUserScopeID()
        // The user identifier is used only to derive a local Keychain namespace;
        // it is never stored in the manifest, UI, or diagnostics.
        let backing: any PodcastCredentialStore = scopeID == nil
            ? TVUnavailableCredentialStore()
            : KeychainPodcastCredentialStore.shared
        PodcastCredentialStoreProvider.configure(
            currentUserScopeID: scopeID,
            backing: backing
        )

        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        guard let data = store.data(forKey: Self.manifestKey) else {
            state = .noSubscriptions
            return
        }

        guard let manifest = try? JSONDecoder().decode(TVSubscriptionManifest.self, from: data) else {
            state = .unavailable("The synchronized subscription manifest could not be read.")
            return
        }

        let items = manifest.entries.compactMap(Self.bootstrapItem(for:))
        state = items.isEmpty ? .noSubscriptions : .loaded(items)
    }

    private static func bootstrapItem(
        for entry: TVSubscriptionManifestEntry
    ) -> TVPremiumBootstrapItem? {
        guard let feedURL = URL(string: entry.feedURL) else { return nil }

        let plan = PodcastPremiumBootstrapPlanner.plan(
            feedURL: feedURL,
            title: entry.title,
            accessProfileID: entry.accessProfileID,
            accessKindRawValue: entry.accessKindRawValue,
            accessProviderIDRawValue: entry.accessProviderID
        )

        let itemState: TVPremiumBootstrapItemState
        switch plan.decision {
        case .publicFeed, .ready:
            itemState = .ready
        case .credentialsRequired(let profileID, _):
            itemState = .credentialsRequired(profileID: profileID)
        }

        return TVPremiumBootstrapItem(
            id: plan.profile.id,
            title: plan.title,
            host: plan.host,
            state: itemState
        )
    }

    private static func currentUserScopeID() async -> String? {
        await withCheckedContinuation { continuation in
            CKContainer(identifier: cloudContainerIdentifier).fetchUserRecordID { recordID, _ in
                continuation.resume(returning: recordID?.recordName)
            }
        }
    }
}

struct TVPremiumBootstrapView: View {
    @EnvironmentObject private var store: TVPremiumBootstrapStore

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .loading:
                    ProgressView("Checking subscriptions…")
                case .noSubscriptions:
                    ContentUnavailableView(
                        "No Subscriptions",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Subscriptions will appear after iCloud synchronization.")
                    )
                case .unavailable(let message):
                    ContentUnavailableView("Unable to Restore", systemImage: "exclamationmark.triangle", description: Text(message))
                case .loaded(let items):
                    List(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label(
                                item.state.title,
                                systemImage: item.state == .ready ? "checkmark.shield" : "lock.shield"
                            )
                            .foregroundStyle(item.state == .ready ? .green : .orange)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        Task { await store.refresh() }
                    }
                }
            }
        }
    }
}
