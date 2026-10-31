import CloudKit
import Foundation

/// Reduces wrapped CloudKit errors to bounded, record-ID-free diagnostic groups.
/// The full error tree remains transient; callers may persist only these summaries.
enum CloudKitFailureAnalyzer {
    struct FailureGroup: Codable, Hashable, Sendable, Identifiable {
        let domain: String
        let code: Int
        let name: String
        let count: Int
        let reason: String?
        let retryAfterSeconds: Double?
        let isBatchFailure: Bool
        /// Fixed reason categories and schema names only, so it is safe to persist.
        var detail: String?

        var id: String { "\(domain):\(code)" }

        var displayName: String {
            domain == CKErrorDomain ? "CKError \(code) — \(name)" : "\(domain) (\(code))"
        }
    }

    struct Report: Codable, Hashable, Sendable {
        let groups: [FailureGroup]
        let visitedErrorCount: Int
        let wasTruncated: Bool

        var actionableGroups: [FailureGroup] {
            groups.filter { !$0.isBatchFailure }
        }

        var batchFailureCount: Int {
            groups.filter(\.isBatchFailure).reduce(0) { $0 + $1.count }
        }

        var summary: String {
            if let primary = actionableGroups.first {
                let collateral = batchFailureCount
                if collateral > 0 {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("%d %@ + %d collateral batch failures", comment: "Summary of a primary CloudKit error and collateral atomic batch failures"),
                        primary.count,
                        primary.displayName,
                        collateral
                    )
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("%d %@ failure(s)", comment: "Summary of a grouped CloudKit error"),
                    primary.count,
                    primary.displayName
                )
            }
            if batchFailureCount > 0 {
                return NSLocalizedString(
                    "Only batch failures were reported; the root cause is not present in the diagnostics.",
                    comment: "Explains that CloudKit diagnostics contain only collateral atomic batch failures"
                )
            }
            return groups.first?.displayName ?? NSLocalizedString(
                "No CloudKit error details were available.",
                comment: "Fallback when a CloudKit event did not include useful error details"
            )
        }

        private enum CodingKeys: String, CodingKey {
            case groups
            case visitedErrorCount
            case wasTruncated
        }

        init(groups: [FailureGroup], visitedErrorCount: Int, wasTruncated: Bool) {
            self.groups = groups
            self.visitedErrorCount = visitedErrorCount
            self.wasTruncated = wasTruncated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups = try container.decode([FailureGroup].self, forKey: .groups)
            visitedErrorCount = try container.decode(Int.self, forKey: .visitedErrorCount)
            wasTruncated = try container.decode(Bool.self, forKey: .wasTruncated)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Localized server reasons may contain values copied from a record.
            // Keep them available to the live screen, but never in persisted history.
            let safeGroups = groups.map {
                FailureGroup(
                    domain: $0.domain,
                    code: $0.code,
                    name: $0.name,
                    count: $0.count,
                    reason: nil,
                    retryAfterSeconds: $0.retryAfterSeconds,
                    isBatchFailure: $0.isBatchFailure,
                    detail: $0.detail
                )
            }
            try container.encode(safeGroups, forKey: .groups)
            try container.encode(visitedErrorCount, forKey: .visitedErrorCount)
            try container.encode(wasTruncated, forKey: .wasTruncated)
        }
    }

    private struct GroupKey: Hashable {
        let domain: String
        let code: Int
    }

    private struct Accumulated {
        var count = 0
        var reason: String?
        var retryAfterSeconds: Double?
        var reasonCategories = Set<String>()
        var schemaNames = Set<String>()
        var userInfoKeys = Set<String>()

        var detail: String? {
            func list(_ values: Set<String>) -> String {
                values.sorted().prefix(maximumDetailValues).joined(separator: ",")
            }
            var parts: [String] = []
            if reasonCategories.isEmpty == false { parts.append("reasons=\(list(reasonCategories))") }
            if schemaNames.isEmpty == false { parts.append("schema=\(list(schemaNames))") }
            if userInfoKeys.isEmpty == false { parts.append("keys=\(list(userInfoKeys))") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Server messages can quote record values, so only these fixed labels and
    /// Core Data's own `CD_` schema names ever leave the transient error.
    private static let reasonCategories: [(phrase: String, category: String)] = [
        ("production schema", "schema_not_in_production"),
        ("cannot create new type", "schema_not_in_production"),
        ("invalid attempt to set value type", "field_type_mismatch"),
        ("not marked indexable", "field_not_indexable"),
        ("not marked queryable", "field_not_queryable"),
        ("too large", "too_large"),
        ("exceeds", "limit_exceeded"),
        ("quota", "quota"),
        ("zone not found", "zone_missing"),
        ("zone does not exist", "zone_missing"),
        ("oplock", "record_conflict"),
        ("already exists", "already_exists"),
        ("permission", "permission"),
        ("schema", "schema_other")
    ]

    private static let maximumDepth = 16
    private static let maximumErrors = 512
    private static let maximumGroups = 24
    private static let maximumReasonLength = 240
    private static let maximumDetailValues = 8

    static func analyze(_ error: Error) -> Report {
        var currentPath = Set<ObjectIdentifier>()
        var accumulated: [GroupKey: Accumulated] = [:]
        var processed = 0
        var truncated = false

        func visit(_ nsError: NSError, depth: Int) {
            guard depth <= maximumDepth, processed < maximumErrors else {
                truncated = true
                return
            }
            let identity = ObjectIdentifier(nsError)
            guard currentPath.insert(identity).inserted else { return }
            defer { currentPath.remove(identity) }
            processed += 1

            var hasChildren = false
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                hasChildren = true
                visit(underlying, depth: depth + 1)
            } else if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                hasChildren = true
                visit(underlying as NSError, depth: depth + 1)
            }

            if let multiple = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                hasChildren = hasChildren || multiple.isEmpty == false
                for child in multiple {
                    visit(child, depth: depth + 1)
                }
            }

            if let partialErrors = partialErrorValues(nsError.userInfo[CKPartialErrorsByItemIDKey]) {
                hasChildren = true
                for child in partialErrors {
                    visit(child, depth: depth + 1)
                }
            }

            let isCloudKit = nsError.domain == CKErrorDomain
            let isPartialWrapper = isCloudKit && nsError.code == CKError.Code.partialFailure.rawValue
            if isPartialWrapper, hasChildren { return }
            if hasChildren { return }

            let key = GroupKey(domain: safeDomain(nsError.domain), code: nsError.code)
            var value = accumulated[key, default: Accumulated()]
            value.count += 1
            if value.reason == nil {
                value.reason = safeReason(from: nsError)
            }
            if value.retryAfterSeconds == nil {
                value.retryAfterSeconds = retryAfter(from: nsError)
            }
            collectDetail(from: nsError, into: &value)
            accumulated[key] = value
        }

        visit(error as NSError, depth: 0)
        let groups = accumulated.map { key, value in
            FailureGroup(
                domain: key.domain,
                code: key.code,
                name: errorName(domain: key.domain, code: key.code),
                count: value.count,
                reason: value.reason,
                retryAfterSeconds: value.retryAfterSeconds,
                isBatchFailure: key.domain == CKErrorDomain
                    && key.code == CKError.Code.batchRequestFailed.rawValue,
                detail: value.detail
            )
        }
        .sorted {
            if $0.isBatchFailure != $1.isBatchFailure { return !$0.isBatchFailure }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }

        return Report(
            groups: Array(groups.prefix(maximumGroups)),
            visitedErrorCount: processed,
            wasTruncated: truncated || groups.count > maximumGroups
        )
    }

    private static func collectDetail(from error: NSError, into value: inout Accumulated) {
        for (key, item) in error.userInfo {
            // Keys are framework identifiers. Their names show what the error
            // carried even when nothing in it can be read safely.
            if key.count <= 64,
               key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }) {
                value.userInfoKeys.insert(key)
            }
            guard let text = item as? String else { continue }
            let lowered = text.lowercased()
            if let match = reasonCategories.first(where: { lowered.contains($0.phrase) }) {
                value.reasonCategories.insert(match.category)
            }
            for match in text.matches(of: /\bCD_[A-Za-z0-9_]{1,64}\b/) {
                value.schemaNames.insert(String(match.output))
            }
        }
    }

    private static func partialErrorValues(_ value: Any?) -> [NSError]? {
        guard let value else { return nil }
        let entries: [Any]
        if let dictionary = value as? NSDictionary {
            entries = dictionary.allValues
        } else if let dictionary = value as? [AnyHashable: Any] {
            entries = Array(dictionary.values)
        } else {
            return nil
        }
        return entries.compactMap { $0 as? NSError }
    }

    private static func safeReason(from error: NSError) -> String? {
        let raw = (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
            ?? (error.userInfo[NSLocalizedDescriptionKey] as? String)
        guard let raw, raw.isEmpty == false else { return nil }
        return String(raw.prefix(maximumReasonLength))
    }

    /// NSError domains are normally static framework identifiers. Reject unusual
    /// values so a custom domain cannot smuggle a URL, path, or user content into
    /// persisted diagnostics.
    private static func safeDomain(_ value: String) -> String {
        let isFrameworkIdentifier = value == CKErrorDomain
            || value.hasSuffix("Domain")
            || value.hasPrefix("kCFErrorDomain")
            || ["com.", "org.", "net."].contains(where: value.hasPrefix)
        guard value.isEmpty == false,
              value.count <= 128,
              isFrameworkIdentifier,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains(scalar)
              }) else {
            return "custom error domain"
        }
        return value
    }

    private static func retryAfter(from error: NSError) -> Double? {
        let raw = error.userInfo["CKErrorRetryAfterKey"]
            ?? error.userInfo["Retry-After"]
        if let number = raw as? NSNumber, number.doubleValue >= 0 {
            return number.doubleValue
        }
        if let date = raw as? Date {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private static func errorName(domain: String, code: Int) -> String {
        guard domain == CKErrorDomain else { return "error" }
        switch CKError.Code(rawValue: code) {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return "code \(code)"
        }
    }
}
