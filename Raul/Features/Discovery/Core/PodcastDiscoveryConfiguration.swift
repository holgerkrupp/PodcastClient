//
//  PodcastDiscoveryConfiguration.swift
//  Raul
//
//  Keeps provider credentials and kill switches out of the UI and out of source.
//
//  Secrets are never hard-coded here. A provider that needs one reads it from
//  the app's Info.plist (build setting / xcconfig) or, for local development,
//  from the process environment. A provider without its key reports
//  `.configurationMissing`, and the registry hides it from discovery.
//

import Foundation

struct PodcastDiscoveryConfiguration: Sendable {
    /// Info.plist key holding provider ids that must not be offered, as an array
    /// of strings, e.g. `<array><string>ardsounds</string></array>`.
    static let disabledProvidersInfoKey = "PodcastDiscoveryDisabledProviders"
    /// UserDefaults key with the same shape, so an integration can be switched
    /// off on a device without shipping a build.
    static let disabledProvidersDefaultsKey = "PodcastDiscoveryDisabledProviders"

    /// Provider identifiers that are switched off.
    let disabledProviderIDs: Set<String>
    /// API keys by provider identifier.
    private let apiKeys: [String: String]

    init(disabledProviderIDs: Set<String> = [], apiKeys: [String: String] = [:]) {
        self.disabledProviderIDs = disabledProviderIDs
        self.apiKeys = apiKeys
    }

    func isEnabled(_ providerID: String) -> Bool {
        disabledProviderIDs.contains(providerID) == false
    }

    func apiKey(for providerID: String) -> String? {
        if let key = apiKeys[providerID], key.isEmpty == false {
            return key
        }
        return nil
    }

    /// Reads the configuration from the app bundle, user defaults and environment.
    static func resolved(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PodcastDiscoveryConfiguration {
        var disabled = Set<String>()

        if let fromBundle = bundle.object(forInfoDictionaryKey: disabledProvidersInfoKey) as? [String] {
            disabled.formUnion(fromBundle.map { $0.lowercased() })
        }

        if let fromDefaults = defaults.array(forKey: disabledProvidersDefaultsKey) as? [String] {
            disabled.formUnion(fromDefaults.map { $0.lowercased() })
        }

        var apiKeys: [String: String] = [:]
        for providerID in PodcastDiscoveryProviderKeys.providersRequiringAPIKeys {
            let infoKey = PodcastDiscoveryProviderKeys.infoPlistKey(for: providerID)
            if let value = bundle.object(forInfoDictionaryKey: infoKey) as? String, value.isEmpty == false {
                apiKeys[providerID] = value
            } else if let value = environment[infoKey], value.isEmpty == false {
                apiKeys[providerID] = value
            }
        }

        return PodcastDiscoveryConfiguration(disabledProviderIDs: disabled, apiKeys: apiKeys)
    }
}

/// Where a provider's credential is expected to live.
enum PodcastDiscoveryProviderKeys {
    /// No shipped provider currently needs a credential. Listing one here makes
    /// its key readable from `Info.plist` (or the environment) under
    /// `PodcastDiscovery<ProviderID>APIKey`.
    static let providersRequiringAPIKeys: [String] = []

    static func infoPlistKey(for providerID: String) -> String {
        "PodcastDiscovery" + providerID.prefix(1).uppercased() + providerID.dropFirst() + "APIKey"
    }
}
