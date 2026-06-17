//
//  ShownotesChapterExtractorTests.swift
//  UpNextTests
//
//  Created by Codex on 13.05.26.
//

import XCTest
@testable import UpNext

final class ShownotesChapterExtractorTests: XCTestCase {
    func testExtractsChapterMarksFromDifferentShownoteFormats() {
        let cases: [ChapterExtractionCase] = [
            ChapterExtractionCase(
                name: "Inline KI supported Kapitelmarken",
                shownotes: "Kapitelmarken, KI-unterstuetzt 00:00:00 - Hallo Dennis! 00:01:00 - Scalable Summit & Instagrams Longform-Strategie 00:17:00 - Facebooks Kampf gegen KI-generierte Falschmeldungen 00:22:22 - Meta vor Gericht: Milliarden durch Betrugsanzeigen 00:26:01 - Meta wehrt sich gegen Gebuehren nach UK Online Safety Act 00:29:00 - Frankreich ermittelt gegen Elon Musk und X 00:32:00 - Groks gefaehrliche Antworten auf Wahnvorstellungen 00:43:00 - Zersplitterung der Alternativen? 00:55:00 - Funktionen und Emotionen",
                expected: [
                    ("00:00:00", "Hallo Dennis!"),
                    ("00:01:00", "Scalable Summit & Instagrams Longform-Strategie"),
                    ("00:17:00", "Facebooks Kampf gegen KI-generierte Falschmeldungen"),
                    ("00:22:22", "Meta vor Gericht: Milliarden durch Betrugsanzeigen"),
                    ("00:26:01", "Meta wehrt sich gegen Gebuehren nach UK Online Safety Act"),
                    ("00:29:00", "Frankreich ermittelt gegen Elon Musk und X"),
                    ("00:32:00", "Groks gefaehrliche Antworten auf Wahnvorstellungen"),
                    ("00:43:00", "Zersplitterung der Alternativen?"),
                    ("00:55:00", "Funktionen und Emotionen")
                ]
            ),
            ChapterExtractionCase(
                name: "HTML list items",
                shownotes: "<p><strong>Kapitel</strong></p><ul><li>00:00:00 Hi Lisa!</li><li>00:02:16 Bibi hat was gesehen</li><li>00:21:53 ApoRed auf Zypern gesichtet?</li></ul>",
                expected: [
                    ("00:00:00", "Hi Lisa!"),
                    ("00:02:16", "Bibi hat was gesehen"),
                    ("00:21:53", "ApoRed auf Zypern gesichtet?")
                ]
            ),
            ChapterExtractionCase(
                name: "Paragraph with pipe separators",
                shownotes: "<p>00:00:00 | Wir brauchen eure Meinung!<br />00:04:10 | VfL Bochum<br />00:16:01 | Holstein Kiel</p>",
                expected: [
                    ("00:00:00", "Wir brauchen eure Meinung!"),
                    ("00:04:10", "VfL Bochum"),
                    ("00:16:01", "Holstein Kiel")
                ]
            ),
            ChapterExtractionCase(
                name: "Minute second timestamps",
                shownotes: "00:00 Intro\n03:32 Lockere A-B Fragen\n21:24 Christians sportlicher Hintergrund",
                expected: [
                    ("00:00:00", "Intro"),
                    ("00:03:32", "Lockere A-B Fragen"),
                    ("00:21:24", "Christians sportlicher Hintergrund")
                ]
            ),
            ChapterExtractionCase(
                name: "WordPress CDATA paragraph with br separated Inhalt",
                shownotes: """
                <![CDATA[...direkt vom Venedig der Wissenschaft.
                <!-- wp:paragraph -->
                <p><strong>Alle Werbepartner </strong>findet ihr <a href="https://linktr.ee/methodischinkorrekt" target="_blank" rel="noreferrer noopener">in diesem Linktree</a>!</p>
                <!-- /wp:paragraph -->
                <!-- wp:paragraph -->
                <p><strong>Inhalt</strong><br>
                00:00:00 Intro<br>
                00:01:08 Venedig<br>
                00:25:08 Essen<br>
                00:30:58 Baf\u{00F6}g<br>
                00:42:29 side stage tickets<br>
                00:50:39 Digitaler Minimalismus<br>
                00:59:53 Thema 1: \u{201C}Gute Einwanderer, schlechte Einwanderer\u{201D}<br>
                01:19:27 Science Snack<br>
                01:24:39 Thema 2: \u{201C}Diagnostisch inkorrekt!\u{201D}<br>
                01:55:47 Schwurbel der Woche<br>
                02:05:47 Outro<br>
                02:07:25 Audiokommentar Porenr\u{00E4}ume<br>
                02:11:22 Audiokommentar Wahrheit</p>
                <!-- /wp:paragraph -->
                <!-- wp:paragraph -->
                <p>Methodisch inkorrekt Folge 396 vom 09.06.2026 direkt vom Venedig der Wissenschaft.</p>
                <!-- /wp:paragraph -->
                <!-- wp:heading -->
                <h2 class="wp-block-heading">Einleitung &amp; Begr\u{00FC}\u{00DF}ung</h2>
                <!-- /wp:heading -->
                <ul>
                """,
                expected: [
                    ("00:00:00", "Intro"),
                    ("00:01:08", "Venedig"),
                    ("00:25:08", "Essen"),
                    ("00:30:58", "Baf\u{00F6}g"),
                    ("00:42:29", "side stage tickets"),
                    ("00:50:39", "Digitaler Minimalismus"),
                    ("00:59:53", "Thema 1: \u{201C}Gute Einwanderer, schlechte Einwanderer\u{201D}"),
                    ("01:19:27", "Science Snack"),
                    ("01:24:39", "Thema 2: \u{201C}Diagnostisch inkorrekt!\u{201D}"),
                    ("01:55:47", "Schwurbel der Woche"),
                    ("02:05:47", "Outro"),
                    ("02:07:25", "Audiokommentar Porenr\u{00E4}ume"),
                    ("02:11:22", "Audiokommentar Wahrheit")
                ]
            )
        ]

        for testCase in cases {
            let extracted = ShownotesChapterExtractor.extractTimeCodesAndTitles(from: testCase.shownotes)
            XCTAssertEqual(extracted?.count, testCase.expected.count, "\(testCase.name) chapter count")
            XCTAssertEqual(extracted, testCase.expectedDictionary, testCase.name)
        }
    }

    func testRequiresAtLeastTwoChapterMarks() {
        let extracted = ShownotesChapterExtractor.extractTimeCodesAndTitles(from: "Shownotes with one 00:00:00 timestamp only")
        XCTAssertNil(extracted)
    }
}

private struct ChapterExtractionCase {
    let name: String
    let shownotes: String
    let expected: [(String, String)]

    var expectedDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: expected)
    }
}
