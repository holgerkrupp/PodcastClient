import Foundation
import XCTest
@testable import UpNext
#if canImport(Security)
import Security
#endif

/// The two phases of this test are run by the reinstall validation script in
/// separate test-host installations. The credential is intentionally fake and
/// is removed by the read phase.
final class PodcastCredentialPersistenceTests: XCTestCase {
    private static let profile = PodcastAccessProfile(
        id: "private-podcast-reinstall-fixture",
        kind: .privateURL,
        resourceURL: URL(string: "https://example.com/reinstall-fixture.xml")!
    )
    private static let credential = PodcastCredential.privateURL(
        URL(string: "https://example.com/reinstall-fixture.xml?token=fake-reinstall-token")!
    )

    func testCredentialPersistenceWritePhase() throws {
#if !REINSTALL_WRITE
        throw XCTSkip("Run through Scripts/validate-private-podcast-reinstall.sh")
#else
        let store = KeychainPodcastCredentialStore.shared
        try? store.removeCredential(for: Self.profile)
        try store.save(Self.credential, for: Self.profile)
        XCTAssertEqual(try store.credential(for: Self.profile), Self.credential)
#endif
    }

    func testCredentialPersistenceReadPhase() throws {
#if !REINSTALL_READ
        throw XCTSkip("Run through Scripts/validate-private-podcast-reinstall.sh")
#else
        let store = KeychainPodcastCredentialStore.shared
        defer { try? store.removeCredential(for: Self.profile) }
        XCTAssertEqual(try store.credential(for: Self.profile), Self.credential)
#endif
    }

#if canImport(Security)
    func testPrivateCredentialUsesDeviceOnlyKeychainAttributes() throws {
        let store = KeychainPodcastCredentialStore.shared
        defer { try? store.removeCredential(for: Self.profile) }
        do {
            try store.save(Self.credential, for: Self.profile)
        } catch PodcastCredentialStoreError.keychain(let status)
                    where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain attribute validation requires a signed test host")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainPodcastCredentialStore.serviceIdentifier,
            kSecAttrAccount as String: Self.profile.id,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            throw XCTSkip("Keychain attribute validation requires a signed test host")
        }
        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        let synchronizable = attributes[kSecAttrSynchronizable as String] as? NSNumber
        XCTAssertNotEqual(synchronizable?.boolValue, true)
        XCTAssertFalse((attributes[kSecAttrAccessGroup as String] as? String ?? "").isEmpty)
    }
#endif
}
