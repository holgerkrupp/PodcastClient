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
            )
        ]

        for testCase in cases {
            let extracted = ShownotesChapterExtractor.extractTimeCodesAndTitles(from: testCase.shownotes)
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
