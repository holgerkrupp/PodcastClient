import CryptoKit
import Foundation
#if canImport(FoundationModels) && (os(iOS) || os(macOS))
import FoundationModels
#endif

enum PersonAssociationState: String, Codable, Sendable {
    case suggested
    case confirmed
    case dismissed
}

struct LocalPersonAssociation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var role: String
    var state: PersonAssociationState
}

enum PersonAssociationPolicy {
    static func confirmed(_ association: LocalPersonAssociation, correctedName: String, correctedRole: String) -> LocalPersonAssociation? {
        let name = correctedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }
        var result = association
        result.name = name
        result.role = correctedRole.trimmingCharacters(in: .whitespacesAndNewlines)
        result.state = .confirmed
        return result
    }

    static func dismissed(_ association: LocalPersonAssociation) -> LocalPersonAssociation {
        var result = association
        result.state = .dismissed
        return result
    }
}

enum LocalPersonAssociationStore {
    static let enabledKey = "onDevicePersonSuggestionsEnabled"
    private static let prefix = "localPersonAssociations.v1."

    static var isModelAvailable: Bool {
#if canImport(FoundationModels) && (os(iOS) || os(macOS))
        SystemLanguageModel.default.isAvailable
#else
        false
#endif
    }

    static func associations(for episodeURL: URL?) -> [LocalPersonAssociation] {
        guard let key = storageKey(for: episodeURL),
              let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([LocalPersonAssociation].self, from: data) else { return [] }
        return values
    }

    static func save(_ associations: [LocalPersonAssociation], for episodeURL: URL?) {
        guard let key = storageKey(for: episodeURL),
              let data = try? JSONEncoder().encode(associations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func suggestions(showNotes: String, transcript: String) async throws -> [LocalPersonAssociation] {
#if canImport(FoundationModels) && (os(iOS) || os(macOS))
        guard SystemLanguageModel.default.isAvailable else { return [] }
        let sections = [
            showNotes.isEmpty ? nil : "SHOW NOTES:\n\(showNotes)",
            transcript.isEmpty ? nil : "PUBLISHER OR ON-DEVICE TRANSCRIPT:\n\(transcript)"
        ].compactMap { $0 }
        guard sections.isEmpty == false else { return [] }
        let prompt = sections.joined(separator: "\n\n").prefix(8_000)
        let instructions = """
        Find up to five named people that the supplied show notes or transcript explicitly identify as a podcast host, co-host, guest, or interviewer. Do not infer identity from voice, pronouns, or context. Ignore people who are only mentioned in passing. Return only names and a short role. These are unverified suggestions for a human to review, not publisher credits.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: String(prompt),
            generating: [SuggestedPerson].self,
            includeSchemaInPrompt: false,
            options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 256)
        )
        var seen = Set<String>()
        return response.content.compactMap { suggestion in
            let name = suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let role = suggestion.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard name.isEmpty == false, name.count <= 80, seen.insert(key).inserted else { return nil }
            return LocalPersonAssociation(id: UUID(), name: name, role: role, state: .suggested)
        }
#else
        return []
#endif
    }

    private static func storageKey(for episodeURL: URL?) -> String? {
        guard let episodeURL else { return nil }
        let digest = SHA256.hash(data: Data(episodeURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + digest
    }
}

#if canImport(FoundationModels) && (os(iOS) || os(macOS))
@Generable(description: "A possible host or guest explicitly identified in show text")
private struct SuggestedPerson {
    @Guide(description: "A person's full name as written in the source text")
    var name: String
    @Guide(description: "A short role such as host, co-host, guest, or interviewer")
    var role: String
}
#endif
