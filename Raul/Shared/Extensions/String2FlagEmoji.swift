//
//  String2FlagEmoji.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import Foundation



public extension String {
    /// Converts a language code to a flag emoji, with manual fallbacks for languages without direct country codes.
    var flagEmoji: String {
        let languageToFlagMap: [String: String] = [
            "ca": "🇪🇸", // Catalan → Spain
            "ar": "🇸🇦", // Arabic → Saudi Arabia
            "en": "🇬🇧", // English → UK (can be 🇺🇸 for US)
            "pt": "🇵🇹", // Portuguese → Portugal (or 🇧🇷 for Brazil)
            "zh": "🇨🇳", // Chinese → China (or 🇹🇼 for Taiwan)
            "ko": "🇰🇷", // Korean → South Korea
            "ja": "🇯🇵", // Japanese → Japan
            "hi": "🇮🇳", // Hindi → India
            "bn": "🇧🇩", // Bengali → Bangladesh (or 🇮🇳 for India)
            "tr": "🇹🇷", // Turkish → Turkey
            "fa": "🇮🇷", // Persian → Iran
            "he": "🇮🇱", // Hebrew → Israel
            "th": "🇹🇭", // Thai → Thailand
            "vi": "🇻🇳", // Vietnamese → Vietnam
            "ms": "🇲🇾", // Malay → Malaysia (or 🇮🇩 for Indonesia)
            "sr": "🇷🇸", // Serbian → Serbia
            "cs": "🇨🇿", // Czech → Czech Republic
            "sk": "🇸🇰", // Slovak → Slovakia
            "hu": "🇭🇺", // Hungarian → Hungary
            "el": "🇬🇷", // Greek → Greece
            "uk": "🇺🇦", // Ukrainian → Ukraine
        ]
        
        // Use manual flag if available
        if let customFlag = languageToFlagMap[self] {
            return customFlag
        }
        
        // Ensure it's a valid two-letter code
        guard self.count == 2 else { return "❓" }
        
        // Convert ISO country codes to flags
        let base: UInt32 = 0x1F1E6
        return self.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + ($0.value - 65))
        }
        .map { String($0) }
        .joined()
    }
    
    func languageName() -> String {
        let locale = Locale(identifier: self)
        return locale.localizedString(forLanguageCode: self) ?? self
    }
}
