import Foundation
import XCTest
@testable import DropToMailCore

final class MIMEMessageBuilderTests: XCTestCase {
    func testUnicodeSubjectFilenameAndBinaryAttachmentRoundTrip() throws {
        let subject = String(repeating: "月次 報告書🎉", count: 12) + ".pdf"
        let filename = "報告書 空白;\"&%🎉.zip"
        // Includes multiple read chunks, padding cases, and all possible byte values.
        let bytes = Data((0..<130_001).map { UInt8($0 % 256) })
        try withArchive(bytes: bytes, fileName: filename, subject: subject) { archive in
            let data = try MIMEMessageBuilder().build(archive: archive, sender: "sender@example.com", recipient: "person+drop@example.co.jp", now: Date(timeIntervalSince1970: 0))
            let message = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(data.allSatisfy { $0 < 128 })
            XCTAssertFalse(message.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            XCTAssertTrue(message.contains("From: sender@example.com\r\nTo: person+drop@example.co.jp\r\n"))
            XCTAssertTrue(message.contains("Date: Thu, 01 Jan 1970 00:00:00 +0000\r\n"))
            XCTAssertTrue(message.contains("MIME-Version: 1.0\r\n"))
            let header = message.components(separatedBy: "\r\n\r\n")[0]
            let words = header.components(separatedBy: "\r\n")
                .filter { $0.hasPrefix("Subject:") || $0.hasPrefix(" =?") }
                .joined(separator: " ").replacingOccurrences(of: "Subject: ", with: "")
                .split(whereSeparator: \.isWhitespace)
            let decodedSubject = try words.map { word -> String in
                let encoded = String(word.dropFirst("=?UTF-8?B?".count).dropLast(2))
                let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
                return try XCTUnwrap(String(data: bytes, encoding: .utf8))
            }.joined()
            XCTAssertEqual(decodedSubject, subject)
            XCTAssertTrue(words.allSatisfy { $0.count <= 75 })

            let parameters = message.components(separatedBy: "\r\n").filter { $0.hasPrefix(" filename*") }
            let encodedName = parameters.map { String($0.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: CharacterSet(charactersIn: ";")) }.joined()
            XCTAssertEqual(String(encodedName.dropFirst("UTF-8''".count)).removingPercentEncoding, filename)
            let boundary = try XCTUnwrap(header.components(separatedBy: "boundary=\"").last?.split(separator: "\"").first).description
            let parts = message.components(separatedBy: "--\(boundary)")
            XCTAssertEqual(parts.count, 4)
            XCTAssertTrue(parts[1].contains("Content-Type: text/plain; charset=UTF-8"))
            let plainBody = parts[1].components(separatedBy: "\r\n\r\n")[1]
            XCTAssertTrue(plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let encodedAttachment = parts[2].components(separatedBy: "\r\n\r\n")[1]
            XCTAssertEqual(Data(base64Encoded: encodedAttachment, options: .ignoreUnknownCharacters), bytes)
            XCTAssertTrue(encodedAttachment.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
            XCTAssertTrue(message.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
            XCTAssertTrue(message.hasSuffix("--\(boundary)--\r\n"))
            XCTAssertFalse(message.contains(archive.jobDirectory.path))
        }
    }

    func testRejectsInjectionAndMultipleRecipients() throws {
        try withArchive(bytes: Data([1]), fileName: "file.zip", subject: "file.pdf") { archive in
            for value in ["a@example.com\r\nBcc: other@example.com", "a@example.com,b@example.com", "Name <a@example.com>"] {
                XCTAssertThrowsError(try MIMEMessageBuilder().build(archive: archive, sender: "sender@example.com", recipient: value)) {
                    XCTAssertEqual($0 as? GmailError, .invalidAddress)
                }
            }
            let injected = PreparedArchive(fileURL: archive.fileURL, fileName: "file.zip", subject: "file\r\nBcc: other@example.com", jobDirectory: archive.jobDirectory)
            XCTAssertThrowsError(try MIMEMessageBuilder().build(archive: injected, sender: "sender@example.com", recipient: "person@example.com")) {
                XCTAssertEqual($0 as? GmailError, .invalidHeader)
            }
        }
    }

    func testOversizedAttachmentFailsBeforeReadingSparseFile() throws {
        try withArchive(bytes: Data(), fileName: "large.zip", subject: "large") { archive in
            let handle = try FileHandle(forWritingTo: archive.fileURL)
            try handle.truncate(atOffset: UInt64(MIMEMessageBuilder.maximumAttachmentBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try MIMEMessageBuilder().build(archive: archive, sender: "sender@example.com", recipient: "person@example.com")) {
                XCTAssertEqual($0 as? GmailError, .messageTooLarge)
            }
        }
    }

    func testMissingAndSymbolicLinkAttachmentsAreRejected() throws {
        try withArchive(bytes: Data(), fileName: "file.zip", subject: "file") { archive in
            try FileManager.default.removeItem(at: archive.fileURL)
            XCTAssertThrowsError(try MIMEMessageBuilder().build(archive: archive, sender: "sender@example.com", recipient: "person@example.com"))
            try FileManager.default.createSymbolicLink(at: archive.fileURL, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            XCTAssertThrowsError(try MIMEMessageBuilder().build(archive: archive, sender: "sender@example.com", recipient: "person@example.com"))
        }
    }

    private func withArchive(bytes: Data, fileName: String, subject: String, body: (PreparedArchive) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attachment.zip")
        try bytes.write(to: url)
        try body(PreparedArchive(fileURL: url, fileName: fileName, subject: subject, jobDirectory: directory))
    }
}
