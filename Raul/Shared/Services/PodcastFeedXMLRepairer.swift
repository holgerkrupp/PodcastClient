import Foundation

/// A deliberately narrow, in-memory repair pass for otherwise usable UTF-8
/// podcast feeds. It fixes encoding defects without attempting to infer XML
/// structure.
struct PodcastFeedXMLRepairResult: Sendable {
    let data: Data
    let bareAmpersands: Int
    let escapedLessThan: Int
    let attributeQuotes: Int

}

enum PodcastFeedXMLRepairer {
    static func repairedDataIfNeeded(from data: Data) -> Data? {
        repairIfNeeded(from: data)?.data
    }

    static func repairIfNeeded(from data: Data) -> PodcastFeedXMLRepairResult? {
        guard let xml = String(data: data, encoding: .utf8), hasUTF8CompatibleDeclaration(xml) else {
            return nil
        }

        var result = String()
        result.reserveCapacity(xml.count)

        var bareAmpersands = 0
        var escapedLessThan = 0
        var attributeQuotes = 0
        var index = xml.startIndex
        var insideTag = false
        var attributeDelimiter: Character?

        while index < xml.endIndex {
            if let delimiter = attributeDelimiter {
                let character = xml[index]
                if character == "&" {
                    if startsValidEntity(in: xml, at: index) {
                        result.append(character)
                    } else {
                        result.append("&amp;")
                        bareAmpersands += 1
                    }
                } else if character == "<" {
                    result.append("&lt;")
                    escapedLessThan += 1
                } else if character == delimiter {
                    if isClosingAttributeDelimiter(in: xml, after: xml.index(after: index)) {
                        attributeDelimiter = nil
                        result.append(character)
                    } else {
                        result.append(delimiter == "\"" ? "&quot;" : "&apos;")
                        attributeQuotes += 1
                    }
                } else {
                    result.append(character)
                }

                index = xml.index(after: index)
                continue
            }

            if insideTag {
                let character = xml[index]
                if character == "\"" || character == "'" {
                    attributeDelimiter = character
                } else if character == ">" {
                    insideTag = false
                }
                result.append(character)
                index = xml.index(after: index)
                continue
            }

            if starts(with: "<![CDATA[", in: xml, at: index) {
                index = appendOpaqueSection("]]>", from: index, in: xml, to: &result)
                continue
            }
            if starts(with: "<!--", in: xml, at: index) {
                index = appendOpaqueSection("-->", from: index, in: xml, to: &result)
                continue
            }
            if starts(with: "<?", in: xml, at: index) {
                index = appendOpaqueSection("?>", from: index, in: xml, to: &result)
                continue
            }
            if starts(with: "<!", in: xml, at: index) {
                index = appendDeclaration(from: index, in: xml, to: &result)
                continue
            }

            let character = xml[index]
            if character == "&" {
                if startsValidEntity(in: xml, at: index) {
                    result.append(character)
                } else {
                    result.append("&amp;")
                    bareAmpersands += 1
                }
            } else if character == "<" {
                if canBeginMarkup(in: xml, after: index) {
                    insideTag = true
                    result.append(character)
                } else {
                    result.append("&lt;")
                    escapedLessThan += 1
                }
            } else {
                result.append(character)
            }
            index = xml.index(after: index)
        }

        guard bareAmpersands > 0 || escapedLessThan > 0 || attributeQuotes > 0,
              let repairedData = result.data(using: .utf8)
        else {
            return nil
        }

        return PodcastFeedXMLRepairResult(
            data: repairedData,
            bareAmpersands: bareAmpersands,
            escapedLessThan: escapedLessThan,
            attributeQuotes: attributeQuotes
        )
    }

    private static func hasUTF8CompatibleDeclaration(_ xml: String) -> Bool {
        var start = xml.startIndex
        if start < xml.endIndex, xml[start] == "\u{FEFF}" {
            start = xml.index(after: start)
        }
        while start < xml.endIndex, xml[start].isWhitespace {
            start = xml.index(after: start)
        }

        let prefix = xml[start...]
        guard prefix.hasPrefix("<?xml") else { return true }
        guard let declarationEnd = prefix.range(of: "?>")?.upperBound else { return false }
        let declaration = String(prefix[..<declarationEnd])
        guard let encodingRange = declaration.range(of: "encoding", options: .caseInsensitive) else {
            return true
        }

        var index = encodingRange.upperBound
        while index < declaration.endIndex, declaration[index].isWhitespace {
            index = declaration.index(after: index)
        }
        guard index < declaration.endIndex, declaration[index] == "=" else { return false }
        index = declaration.index(after: index)
        while index < declaration.endIndex, declaration[index].isWhitespace {
            index = declaration.index(after: index)
        }
        guard index < declaration.endIndex, declaration[index] == "\"" || declaration[index] == "'" else {
            return false
        }

        let delimiter = declaration[index]
        let valueStart = declaration.index(after: index)
        guard let valueEnd = declaration[valueStart...].firstIndex(of: delimiter) else { return false }
        let encoding = declaration[valueStart..<valueEnd].lowercased()
        return encoding == "utf-8" || encoding == "utf8"
    }

    private static func appendOpaqueSection(
        _ terminator: String,
        from start: String.Index,
        in xml: String,
        to result: inout String
    ) -> String.Index {
        guard let terminatorRange = xml[start...].range(of: terminator) else {
            result.append(contentsOf: xml[start...])
            return xml.endIndex
        }
        result.append(contentsOf: xml[start..<terminatorRange.upperBound])
        return terminatorRange.upperBound
    }

    private static func appendDeclaration(
        from start: String.Index,
        in xml: String,
        to result: inout String
    ) -> String.Index {
        var index = xml.index(after: start)
        var quote: Character?
        var internalSubsetDepth = 0

        while index < xml.endIndex {
            let character = xml[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                internalSubsetDepth += 1
            } else if character == "]", internalSubsetDepth > 0 {
                internalSubsetDepth -= 1
            } else if character == ">", internalSubsetDepth == 0 {
                let end = xml.index(after: index)
                result.append(contentsOf: xml[start..<end])
                return end
            }
            index = xml.index(after: index)
        }

        result.append(contentsOf: xml[start...])
        return xml.endIndex
    }

    private static func starts(with value: String, in xml: String, at index: String.Index) -> Bool {
        xml[index...].hasPrefix(value)
    }

    private static func canBeginMarkup(in xml: String, after lessThanIndex: String.Index) -> Bool {
        let next = xml.index(after: lessThanIndex)
        guard next < xml.endIndex else { return false }
        let character = xml[next]
        if character == "!" || character == "?" {
            return true
        }
        if character == "/" {
            let nameStart = xml.index(after: next)
            return nameStart < xml.endIndex && isXMLNameStartCharacter(xml[nameStart])
        }
        return isXMLNameStartCharacter(character)
    }

    private static func startsValidEntity(in xml: String, at ampersandIndex: String.Index) -> Bool {
        let nextIndex = xml.index(after: ampersandIndex)
        guard nextIndex < xml.endIndex else { return false }

        let remaining = xml[nextIndex...]
        for entity in ["amp;", "lt;", "gt;", "quot;", "apos;"] where remaining.hasPrefix(entity) {
            return true
        }

        guard remaining.first == "#" else { return false }
        var index = xml.index(after: nextIndex)
        var isHex = false
        if index < xml.endIndex, xml[index] == "x" || xml[index] == "X" {
            isHex = true
            index = xml.index(after: index)
        }

        let digitStart = index
        while index < xml.endIndex {
            let scalar = xml[index].unicodeScalars.first
            let isValidDigit = if isHex {
                scalar.map { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) } ?? false
            } else {
                scalar.map { CharacterSet.decimalDigits.contains($0) } ?? false
            }
            guard isValidDigit else { break }
            index = xml.index(after: index)
        }

        return digitStart < index && index < xml.endIndex && xml[index] == ";"
    }

    private static func isClosingAttributeDelimiter(in xml: String, after delimiterIndex: String.Index) -> Bool {
        var index = delimiterIndex
        while index < xml.endIndex, xml[index].isWhitespace {
            index = xml.index(after: index)
        }
        guard index < xml.endIndex else { return true }

        let character = xml[index]
        if character == ">" || character == "/" || character == "?" {
            return true
        }
        guard isXMLNameStartCharacter(character) else { return false }

        index = xml.index(after: index)
        while index < xml.endIndex, isXMLNameCharacter(xml[index]) {
            index = xml.index(after: index)
        }
        while index < xml.endIndex, xml[index].isWhitespace {
            index = xml.index(after: index)
        }
        return index < xml.endIndex && xml[index] == "="
    }

    private static func isXMLNameStartCharacter(_ character: Character) -> Bool {
        character == "_" || character == ":" || character.isLetter
    }

    private static func isXMLNameCharacter(_ character: Character) -> Bool {
        isXMLNameStartCharacter(character) || character.isNumber || character == "-" || character == "."
    }
}
