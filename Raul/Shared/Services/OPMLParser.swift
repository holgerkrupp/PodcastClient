//
//  OPMLParser.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import Foundation

enum OPMLImportSanitizer {
    static func sanitizedDataIfNeeded(from data: Data) -> Data? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        let sanitized = sanitize(xml)
        guard sanitized != xml else { return nil }
        return sanitized.data(using: .utf8)
    }

    static func sanitize(_ xml: String) -> String {
        var result = String()
        result.reserveCapacity(xml.count)

        var index = xml.startIndex
        var insideTag = false
        var attributeDelimiter: Character?

        while index < xml.endIndex {
            let character = xml[index]

            if let delimiter = attributeDelimiter {
                if character == "&" {
                    if startsValidEntity(in: xml, at: index) {
                        result.append(character)
                    } else {
                        result.append("&amp;")
                    }
                } else if character == "<" {
                    result.append("&lt;")
                } else if character == ">" {
                    result.append("&gt;")
                } else if character == delimiter {
                    if isClosingAttributeDelimiter(in: xml, after: xml.index(after: index)) {
                        attributeDelimiter = nil
                        result.append(character)
                    } else if delimiter == "\"" {
                        result.append("&quot;")
                    } else {
                        result.append("&apos;")
                    }
                } else {
                    result.append(character)
                }

                index = xml.index(after: index)
                continue
            }

            if insideTag {
                if character == "\"" || character == "'" {
                    attributeDelimiter = character
                    result.append(character)
                } else {
                    if character == ">" {
                        insideTag = false
                    }
                    result.append(character)
                }
            } else {
                if character == "<" {
                    insideTag = true
                }
                result.append(character)
            }

            index = xml.index(after: index)
        }

        return result
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


class OPMLParser: NSObject, XMLParserDelegate{
    var podcastFeeds: [PodcastFeed] = []

    private enum MetadataAttribute {
        static let lastRefresh = "upnextLastRefresh"
        static let lastEpisodeDate = "upnextLastEpisodeDate"
        static let lastEpisodeURL = "upnextLastEpisodeURL"
    }
    
    func parserDidStartDocument(_ parser: XMLParser) {
        podcastFeeds.removeAll()
    }
    
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        
        // print("OPML Parser started: \(elementName)")
        
        let currentElement = elementName.lowercased()

        switch currentElement {
        case "opml":
            return
        case "outline":
            let normalizedAttributes = attributeDict.reduce(into: [String: String]()) { result, attribute in
                result[attribute.key.lowercased()] = attribute.value
            }
            let outlineType = normalizedAttributes["type"]?.lowercased()
            let isPodcastOutline = outlineType == nil || outlineType == "rss" || outlineType == "podcast"

            guard
                isPodcastOutline,
                let feedURLString = normalizedAttributes["xmlurl"],
                let feedURL = URL(string: feedURLString)
            else {
                return
            }

            let newPodcast = PodcastFeed(url: feedURL, fetchMetadataIfNeeded: false)
            newPodcast.title = normalizedAttributes["text"] ?? normalizedAttributes["title"]

            if let dateString = attributeDict[MetadataAttribute.lastRefresh] {
                newPodcast.importedLastRefresh = Date.dateFromOPMLMetadata(dateString: dateString)
            }

            if let dateString = attributeDict[MetadataAttribute.lastEpisodeDate] {
                newPodcast.importedLastEpisodeDate = Date.dateFromOPMLMetadata(dateString: dateString)
            }

            if let episodeURLString = attributeDict[MetadataAttribute.lastEpisodeURL],
               let episodeURL = URL(string: episodeURLString) {
                newPodcast.importedLastEpisodeURL = episodeURL
            }

            podcastFeeds.append(newPodcast)

        default:
            return
        }
    }
    
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        
        // print("OPML Parser ended: \(elementName)")
        switch elementName.lowercased() {
        case "outline":
            return
        default:
            return
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        
    }
    
    
}
