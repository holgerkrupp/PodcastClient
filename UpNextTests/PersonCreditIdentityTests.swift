import XCTest
@testable import UpNext

final class PersonCreditIdentityTests: XCTestCase {
    func testNameOnlyCreditsAreScopedByFeedAndRole() {
        let candidate = PersonInfo(name: "Alex Kim", role: "guest", href: nil, img: nil)

        XCTAssertTrue(PersonCreditIdentity.matches(
            candidate,
            reference: nil,
            name: "alex kim",
            role: "Guest",
            feedURL: "https://example.com/feed.xml",
            episodeFeedURL: "https://example.com/feed.xml"
        ))
        XCTAssertFalse(PersonCreditIdentity.matches(
            candidate,
            reference: nil,
            name: "Alex Kim",
            role: "host",
            feedURL: "https://example.com/feed.xml",
            episodeFeedURL: "https://example.com/feed.xml"
        ))
        XCTAssertFalse(PersonCreditIdentity.matches(
            candidate,
            reference: nil,
            name: "Alex Kim",
            role: "guest",
            feedURL: "https://one.example/feed.xml",
            episodeFeedURL: "https://two.example/feed.xml"
        ))
    }

    func testPublisherReferenceSurvivesRoleAndNameFormattingChanges() {
        let candidate = PersonInfo(
            name: "Alexander Kim",
            role: "host",
            href: URL(string: "https://people.example/alex?utm_source=feed"),
            img: nil
        )

        XCTAssertTrue(PersonCreditIdentity.matches(
            candidate,
            reference: "https://people.example/alex",
            name: "Alex Kim",
            role: "guest",
            feedURL: nil,
            episodeFeedURL: nil
        ))
    }

    func testNameOnlyCreditsDoNotCrossPrivateOrMissingFeedIdentity() {
        let candidate = PersonInfo(name: "Sam Lee", role: "guest", href: nil, img: nil)

        XCTAssertFalse(PersonCreditIdentity.matches(
            candidate,
            reference: nil,
            name: "Sam Lee",
            role: "guest",
            feedURL: "https://user:secret@example.com/feed.xml",
            episodeFeedURL: "https://user:secret@example.com/feed.xml"
        ))
        XCTAssertFalse(PersonCreditIdentity.matches(
            candidate,
            reference: nil,
            name: "Sam Lee",
            role: "guest",
            feedURL: nil,
            episodeFeedURL: nil
        ))
    }
}
