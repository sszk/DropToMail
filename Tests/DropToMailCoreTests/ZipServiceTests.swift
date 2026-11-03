import CLibzip
import Foundation
import XCTest
@testable import DropToMailCore

final class ZipServiceTests: XCTestCase {
    private let service = ZipService()

    func testCreatesPasswordProtectedArchiveForSingleFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archive = try service.createArchive(
            inputs: [fixture.file],
            password: "correct horse battery staple",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defer { try? service.cleanup(jobDirectory: archive.jobDirectory) }

        XCTAssertEqual(archive.fileName, "report.zip")
        XCTAssertEqual(archive.subject, "report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.fileURL.path))
        assertCanRead(archive.fileURL, password: "correct horse battery staple", expected: Data("sample contents".utf8))
    }

    func testPreservesFolderStructureAndSkipsMacMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let folder = fixture.directory.appendingPathComponent("日本語 Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("inside file.txt"))
        try Data("metadata".utf8).write(to: folder.appendingPathComponent(".DS_Store"))

        let archive = try service.createArchive(inputs: [folder], password: "zip-pass")
        defer { try? service.cleanup(jobDirectory: archive.jobDirectory) }

        XCTAssertEqual(archive.fileName, "日本語 Folder.zip")
        XCTAssertEqual(archive.subject, "日本語 Folder")
        assertCanRead(
            archive.fileURL,
            password: "zip-pass",
            expected: Data("nested".utf8),
            entry: "日本語 Folder/inside file.txt"
        )
    }

    func testRejectsDuplicateArchiveNames() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let duplicate = fixture.directory.appendingPathComponent("other/report.pdf")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("different".utf8).write(to: duplicate)

        XCTAssertThrowsError(try service.createArchive(
            inputs: [fixture.file, duplicate],
            password: "zip-pass"
        ))
    }

    func testNamesMultipleFileArchivesAndIncludesUnicodeNames() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let second = fixture.directory.appendingPathComponent("資料 (最終).txt")
        try Data("second".utf8).write(to: second)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let archive = try service.createArchive(
            inputs: [fixture.file, second],
            password: "zip-pass",
            now: fixedDate
        )
        defer { try? service.cleanup(jobDirectory: archive.jobDirectory) }

        XCTAssertTrue(archive.fileName.hasPrefix("Files_"))
        XCTAssertTrue(archive.fileName.hasSuffix(".zip"))
        XCTAssertEqual(archive.subject, archive.fileName)
        assertCanRead(archive.fileURL, password: "zip-pass", expected: Data("second".utf8), entry: "資料 (最終).txt")
    }

    func testRejectsSymbolicLinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let link = fixture.directory.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)

        XCTAssertThrowsError(try service.createArchive(inputs: [link], password: "zip-pass"))
    }

    func testDoesNotLeaveWorkspaceAfterFailedCreation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try FileManager.default.contentsOfDirectory(atPath: service.temporaryRoot.path).count

        XCTAssertThrowsError(try service.createArchive(inputs: [fixture.file], password: ""))
        let after = try FileManager.default.contentsOfDirectory(atPath: service.temporaryRoot.path).count
        XCTAssertEqual(after, before)
    }

    private func makeFixture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("report.pdf")
        try Data("sample contents".utf8).write(to: file)
        return (directory, file)
    }

    private func assertCanRead(
        _ url: URL,
        password: String,
        expected: Data,
        entry: String = "report.pdf",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var error: Int32 = 0
        guard let archive = url.path.withCString({ zip_open($0, ZIP_RDONLY, &error) }) else {
            XCTFail("Could not reopen archive.", file: file, line: line)
            return
        }
        defer { zip_discard(archive) }

        let index = entry.withCString { zip_name_locate(archive, $0, ZIP_FL_ENC_GUESS) }
        XCTAssertGreaterThanOrEqual(index, 0, file: file, line: line)
        var stat = zip_stat_t()
        XCTAssertEqual(zip_stat_index(archive, zip_uint64_t(index), ZIP_FL_ENC_GUESS, &stat), 0, file: file, line: line)
        XCTAssertEqual(stat.encryption_method, zip_uint16_t(ZIP_EM_TRAD_PKWARE), file: file, line: line)
        guard let stream = zip_fopen_index_encrypted(archive, zip_uint64_t(index), 0, password) else {
            XCTFail("Could not open encrypted entry.", file: file, line: line)
            return
        }
        defer { zip_fclose(stream) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBufferPointer {
            guard let baseAddress = $0.baseAddress else { return zip_int64_t(-1) }
            return zip_fread(stream, baseAddress, zip_uint64_t($0.count))
        }
        XCTAssertGreaterThanOrEqual(count, 0, file: file, line: line)
        XCTAssertEqual(Data(bytes.prefix(Int(count))), expected, file: file, line: line)
    }
}
