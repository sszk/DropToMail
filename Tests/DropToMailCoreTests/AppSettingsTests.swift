import XCTest
@testable import DropToMailCore

final class AppSettingsTests: XCTestCase {
    func testAcceptsCommonWorkspaceAddresses() {
        XCTAssertTrue(AppSettings.isValidEmail("person@example.com"))
        XCTAssertTrue(AppSettings.isValidEmail("first.last+drop@example.co.jp"))
    }

    func testRejectsMalformedAddresses() {
        for value in ["", "person", "person@", "@example.com", "person@example", "person @example.com", "a@@example.com",
                      "a@example.com,b@example.com", "Person <a@example.com>",
                      "a@example.com\r\nBcc: other@example.com", "a..b@example.com",
                      "a@example..com", "a@-example.com", "a@example.com\n", "あ@example.com"] {
            XCTAssertFalse(AppSettings.isValidEmail(value), "Expected invalid address: \(value)")
        }
    }
}
