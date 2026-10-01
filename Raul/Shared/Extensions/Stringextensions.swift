//
//  attributedString.swift
//  PodcastClient
//
//  Created by Holger Krupp on 17.12.23.
//

import Foundation
import SwiftUI

extension String {
    var podcastTitleComparisonKey: String? {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let pieces = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
        let key = pieces.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard key.count > 2 else { return nil }
        return key
    }

    func toDetectedAttributedString() -> AttributedString {
        
        var attributedString = AttributedString(self)
        
        let types = NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        
        guard let detector = try? NSDataDetector(types: types) else {
            return attributedString
        }
        
        let matches = detector.matches(in: self, options: [], range: NSRange(location: 0, length: count))
        
        for match in matches {
            let range = match.range
            let startIndex = attributedString.index(attributedString.startIndex, offsetByCharacters: range.lowerBound)
            let endIndex = attributedString.index(startIndex, offsetByCharacters: range.length)
            // Set the url for links
            if match.resultType == .link, let url = match.url {
                attributedString[startIndex..<endIndex].link = url
                // If it's an email, set the background color
                if url.scheme == "mailto" {
                    attributedString[startIndex..<endIndex].backgroundColor = .red.opacity(0.3)
                }
            }
            // Set the url for phone numbers
            if match.resultType == .phoneNumber, let phoneNumber = match.phoneNumber {
                let url = URL(string: "tel:\(phoneNumber)")
                attributedString[startIndex..<endIndex].link = url
            }
        }
        return attributedString
    }
}

extension String {
    var isValidURL: Bool {
        // Use NSDataDetector to check for a valid link
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let detector else { return false }
        guard let match = detector.firstMatch(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count)),
              match.range.length == self.utf16.count,
              let url = URL(string: self),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = url.host, host.contains(".")
        else {
            return false
        }
        return true
    }
    
    /// Checks if the string is a valid, reachable URL by performing a HEAD request.
    func isReachableURL(timeout: TimeInterval = 5.0) async -> Bool {
        guard self.isValidURL, let url = URL(string: self) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200..<400).contains(httpResponse.statusCode)
            }
        } catch {
            // ignore error, return false
        }
        return false
    }
    
    /// Returns HTTP status and final URL (after considering potential Location header via your URL.status()).
    /// This does not follow redirects itself; it mirrors your URL.status() behavior.
    func reachabilityStatus(timeout: TimeInterval = 5.0) async -> (statusCode: Int?, finalURL: URL?)? {
        guard self.isValidURL, let url = URL(string: self) else { return nil }
        do {
            let status = try await url.status()
            return (status?.statusCode, status?.newURL ?? url)
        } catch {
            return nil
        }
    }
}

extension String{
    var durationAsSeconds:Double?{
        
         let timeArray = self.components(separatedBy: ":")
            var seconds = 0.0
            for element in timeArray{
                if let double = Double(element){
                    seconds = (seconds + double) * 60
                }
            }
            seconds = seconds / 60
        
        if seconds.isNaN{
            return nil
        }else{
            return seconds
        }
    }
}

extension String{
    /// Returns a compact, readable representation for HTML descriptions shown
    /// in list rows. The original HTML should remain stored for rich views.
    func plainTextFromHTML() -> String? {
        var result = String()
        result.reserveCapacity(count)

        var index = startIndex
        var containsMarkupOrEntity = false

        while index < endIndex {
            let character = self[index]

            if character == "<", let tagEnd = endOfHTMLTag(startingAt: index) {
                let tag = self[index...tagEnd]
                let tagName = Self.htmlTagName(in: tag)
                let isDeclaration = tag.dropFirst().first == "!" || tag.dropFirst().first == "?"

                if tagName != nil || isDeclaration {
                    containsMarkupOrEntity = true
                    if let tagName, Self.blockHTMLTags.contains(tagName) {
                        result.append(" ")
                    }
                    index = self.index(after: tagEnd)
                    continue
                }
            } else if character == "<", looksLikeUnclosedHTMLTag(startingAt: index) {
                // A truncated feed description can end in an opening tag. Treat
                // the tag as markup, but do not let it consume a normal "a < b"
                // comparison.
                containsMarkupOrEntity = true
                if let tagName = Self.htmlTagName(in: self[index...]),
                   Self.blockHTMLTags.contains(tagName) {
                    result.append(" ")
                }
                break
            }

            if character == "&", let entityEnd = endOfHTMLEntity(startingAt: index) {
                let entity = self[self.index(after: index)..<entityEnd]
                containsMarkupOrEntity = true

                if let decoded = Self.decodeHTMLEntity(entity) {
                    result.append(decoded)
                } else {
                    // Unknown entities are left visible rather than silently
                    // losing feed text.
                    result.append(contentsOf: self[index...entityEnd])
                }

                index = self.index(after: entityEnd)
                continue
            }

            result.append(character)
            index = self.index(after: index)
        }

        // Avoid changing ordinary descriptions, including their whitespace.
        guard containsMarkupOrEntity else { return self }

        return result
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private static let blockHTMLTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div",
        "dl", "dt", "figcaption", "figure", "footer", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol",
        "p", "pre", "section", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul"
    ]

    private func endOfHTMLTag(startingAt start: String.Index) -> String.Index? {
        var index = self.index(after: start)
        var quote: Character?

        while index < endIndex {
            let character = self[index]

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                self.formIndex(after: &index)
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            self.formIndex(after: &index)
        }

        return nil
    }

    private func looksLikeUnclosedHTMLTag(startingAt start: String.Index) -> Bool {
        var index = self.index(after: start)

        while index < endIndex, self[index].isWhitespace {
            self.formIndex(after: &index)
        }
        if index < endIndex, self[index] == "/" {
            self.formIndex(after: &index)
            while index < endIndex, self[index].isWhitespace {
                self.formIndex(after: &index)
            }
        }

        guard index < endIndex else { return false }
        let character = self[index]
        return character.isASCII && character.isLetter
    }

    private func endOfHTMLEntity(startingAt start: String.Index) -> String.Index? {
        var index = self.index(after: start)
        guard index < endIndex else { return nil }

        let firstCharacter = self[index]
        guard firstCharacter == "#" || (firstCharacter.isASCII && firstCharacter.isLetter) else {
            return nil
        }

        var length = 0
        while index < endIndex, length < 32 {
            let character = self[index]
            if character == ";" {
                return index
            }
            guard character == "#" || character == "x" || character == "X"
                    || (character.isASCII && character.isLetter)
                    || (character.isASCII && character.isNumber) else {
                return nil
            }
            length += 1
            self.formIndex(after: &index)
        }

        return nil
    }

    private static func htmlTagName(in tag: Substring) -> String? {
        var index = tag.startIndex
        guard index < tag.endIndex, tag[index] == "<" else { return nil }
        tag.formIndex(after: &index)

        while index < tag.endIndex, tag[index].isWhitespace {
            tag.formIndex(after: &index)
        }
        if index < tag.endIndex, tag[index] == "/" {
            tag.formIndex(after: &index)
            while index < tag.endIndex, tag[index].isWhitespace {
                tag.formIndex(after: &index)
            }
        }

        let nameStart = index
        while index < tag.endIndex,
              tag[index].isASCII && (tag[index].isLetter || tag[index].isNumber) {
            tag.formIndex(after: &index)
        }
        guard nameStart != index else { return nil }

        return tag[nameStart..<index].lowercased()
    }

    private static func decodeHTMLEntity(_ entity: Substring) -> Character? {
        let value = String(entity)

        switch value.lowercased() {
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        case "copy": return "©"
        case "reg": return "®"
        case "trade": return "™"
        case "bull": return "•"
        case "middot": return "·"
        case "hellip": return "…"
        case "ndash": return "–"
        case "mdash": return "—"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "euro": return "€"
        case "pound": return "£"
        case "yen": return "¥"
        case "cent": return "¢"
        default:
            if value.hasPrefix("#x") || value.hasPrefix("#X"),
               let number = UInt32(value.dropFirst(2), radix: 16),
               let scalar = UnicodeScalar(number) {
                return Character(scalar)
            }

            if value.hasPrefix("#"),
               let number = UInt32(value.dropFirst()),
               let scalar = UnicodeScalar(number) {
                return Character(scalar)
            }

            return nil
        }
    }
}
