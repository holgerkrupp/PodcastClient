//
//  attributedString.swift
//  PodcastClient
//
//  Created by Holger Krupp on 17.12.23.
//

import Foundation
import SwiftUI

extension String {
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
    func decodeHTML() -> String? {
        guard let data = self.data(using: .utf8) else {
            return nil
        }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        do {
            let attributedString = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return attributedString.string
        } catch {
            // print("Error decoding HTML entities: \(error)")
            return nil
        }
    }
}
