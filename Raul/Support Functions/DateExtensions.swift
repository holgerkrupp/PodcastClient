//
//  DateExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//

import Foundation



extension Date {
    
    private static func cachedThreadLocalObjectWithKey<T: AnyObject>(key: String, create: () -> T) -> T {
        let threadDictionary = Thread.current.threadDictionary
        if let cachedObject = threadDictionary[key] as! T? {
            return cachedObject
        }
        else {
            let newObject = create()
            threadDictionary[key] = newObject
            return newObject
        }
    }
    
    private static func RFC1123DateFormatter() -> DateFormatter {
        return cachedThreadLocalObjectWithKey(key: "RFC1123DateFormatter") {
            let locale = Locale(identifier: "en_US")
            let timeZone = TimeZone(identifier: "GMT")
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            return dateFormatter
        }
    }
    
    private static func RFC850DateFormatter() -> DateFormatter {
        return cachedThreadLocalObjectWithKey(key: "RFC850DateFormatter") {
            let locale = Locale(identifier: "en_US")
            let timeZone = TimeZone(identifier: "GMT")
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss z"
            return dateFormatter
        }
    }
    
    private static func asctimeDateFormatter() -> DateFormatter {
        return cachedThreadLocalObjectWithKey(key: "asctimeDateFormatter") {
            let locale = Locale(identifier: "en_US")
            let timeZone = TimeZone(identifier: "GMT")
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return dateFormatter
        }
    }

    private static func ISO8601DateTimeFormatter() -> ISO8601DateFormatter {
        return cachedThreadLocalObjectWithKey(key: "ISO8601DateTimeFormatter") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }
    }

    private static func ISO8601FractionalDateTimeFormatter() -> ISO8601DateFormatter {
        return cachedThreadLocalObjectWithKey(key: "ISO8601FractionalDateTimeFormatter") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }
    }
    
    static func dateFromRFC1123(dateString:String) -> Date? {
        
        var date:Date?
        //RFC1123
        date = Date.RFC1123DateFormatter().date(from: dateString)
        if date != nil {
            return date
        }
        
        //RFC850
        date = Date.RFC850DateFormatter().date(from: dateString)
        if date != nil {
            return date
        }
        
        //asctime-date
        date = Date.asctimeDateFormatter().date(from: dateString)
        if date != nil {
            return date
        }
        return nil
    }

    static func dateFromOPMLMetadata(dateString: String) -> Date? {
        if let date = Date.ISO8601FractionalDateTimeFormatter().date(from: dateString) {
            return date
        }

        if let date = Date.ISO8601DateTimeFormatter().date(from: dateString) {
            return date
        }

        return Date.dateFromRFC1123(dateString: dateString)
    }
    
    func RFC1123String() -> String? {
        return Date.RFC1123DateFormatter().string(from: self)
    }

    func opmlMetadataString() -> String {
        Date.ISO8601FractionalDateTimeFormatter().string(from: self)
    }
}
