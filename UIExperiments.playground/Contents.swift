import Foundation

let htmlEncodedText = "<![CDATA[... direkt vom TikTok-Trend der Wissenschaft.\n<!-- wp:paragraph -->\n<p>00:00:00 Intro<br>00:04:13 Technikfaszination<br>00:22:10 Dr. Whatson live<br>00:26:50 Software Audacity<br>00:38:06 Thema 1: “Diamantregen”<br>01:03:15 Experiment<br>01:08:43 Thema 2: \"Druck auf der Hüfte\"<br>01:24:02 Schwurbel<br>01:43:37 Hausmeisterei<br>01:50:38 Outro</p>\n<!-- /wp:paragraph -->\n<!-- wp:paragraph -->\n<p><strong>Begrüßung</strong>: </p>\n<!-- /wp:paragraph -->"

func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String] {
    var result = [String: String]()
    
    let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=<br>|\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)
    let matches = regex.matches(in: htmlEncodedText, options: [], range: NSRange(location: 0, length: htmlEncodedText.utf16.count))
    
    for match in matches {
        if let titleRange = Range(match.range(at: 1), in: htmlEncodedText),
           let timeCodeRange = Range(match.range, in: htmlEncodedText) {
            let title = String(htmlEncodedText[titleRange])
            let timeCode = String(htmlEncodedText[timeCodeRange].split(separator: " ")[0]) // Only take the time code part
            result[timeCode] = title
        }
    }
    
    return result
}

let extractedData = extractTimeCodesAndTitles(from: htmlEncodedText)
print(extractedData)
