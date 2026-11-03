import CLibzip
import Darwin
import Foundation

public struct PreparedArchive: Sendable {
    public let fileURL: URL
    public let fileName: String
    public let subject: String
    public let jobDirectory: URL
}

public enum ZipServiceError: Error, LocalizedError {
    case noInputs
    case invalidPassword
    case unsupportedItem(String)
    case duplicateEntry(String)
    case archiveCreation(String)
    case archiveWrite(String)
    case archiveValidation(String)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "Drop at least one file or folder."
        case .invalidPassword:
            return "Set a ZIP password that does not contain a null character."
        case .unsupportedItem(let path):
            return "Unsupported file or symbolic link: \(path)"
        case .duplicateEntry(let name):
            return "Multiple dropped items have the same archive name: \(name)"
        case .archiveCreation(let message):
            return "Could not create ZIP archive: \(message)"
        case .archiveWrite(let message):
            return "Could not write ZIP archive: \(message)"
        case .archiveValidation(let message):
            return "Could not validate ZIP archive: \(message)"
        }
    }
}

public struct ZipService: Sendable {
    public static let temporaryRootName = "DropToMail-jobs"

    public init() {}

    private var fileManager: FileManager { .default }

    public var temporaryRoot: URL {
        fileManager.temporaryDirectory.appendingPathComponent(Self.temporaryRootName, isDirectory: true)
    }

    public func createArchive(
        inputs: [URL],
        password: String,
        now: Date = Date()
    ) throws -> PreparedArchive {
        guard !inputs.isEmpty else { throw ZipServiceError.noInputs }
        guard !password.isEmpty, !password.contains("\0") else {
            throw ZipServiceError.invalidPassword
        }
        try checkCancellation()

        try createPrivateDirectoryIfNeeded(at: temporaryRoot)
        let jobDirectory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let naming = archiveNaming(inputs: inputs, now: now)
            let archiveURL = jobDirectory.appendingPathComponent(naming.fileName)
            let entries = try collectEntries(inputs: inputs)
            guard !entries.isEmpty else { throw ZipServiceError.noInputs }
            try writeArchive(entries, to: archiveURL, password: password)
            try validateArchive(at: archiveURL, password: password, expectedFiles: entries.filter { !$0.isDirectory }.count)
            return PreparedArchive(
                fileURL: archiveURL,
                fileName: naming.fileName,
                subject: naming.subject,
                jobDirectory: jobDirectory
            )
        } catch let originalError {
            do {
                try cleanup(jobDirectory: jobDirectory)
            } catch let cleanupError {
                throw ZipServiceError.archiveWrite(
                    "\(originalError.localizedDescription) Temporary files could not be removed: \(cleanupError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    public func cleanup(jobDirectory: URL) throws {
        let root = temporaryRoot.standardizedFileURL
        let target = jobDirectory.standardizedFileURL
        guard target.deletingLastPathComponent() == root,
              UUID(uuidString: target.lastPathComponent) != nil
        else {
            throw ZipServiceError.archiveWrite("Refusing to remove a directory outside the job workspace.")
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    public func cleanupAbandonedJobs() throws {
        try createPrivateDirectoryIfNeeded(at: temporaryRoot)
        let children = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try cleanup(jobDirectory: child)
        }
    }

    private struct Entry {
        let source: URL?
        let archivePath: String
        let isDirectory: Bool
    }

    private func collectEntries(inputs: [URL]) throws -> [Entry] {
        var entries: [Entry] = []
        var names = Set<String>()

        func add(_ entry: Entry) throws {
            guard names.insert(entry.archivePath).inserted else {
                throw ZipServiceError.duplicateEntry(entry.archivePath)
            }
            entries.append(entry)
        }

        for input in inputs {
            try checkCancellation()
            let url = input.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ZipServiceError.unsupportedItem(url.path)
            }
            let rootName = url.lastPathComponent
            guard !shouldSkip(rootName) else { continue }
            guard !rootName.isEmpty, rootName != ".", rootName != ".." else {
                throw ZipServiceError.unsupportedItem(url.path)
            }

            if values.isDirectory == true {
                try add(Entry(source: nil, archivePath: rootName + "/", isDirectory: true))
                try collectDirectory(url, archivePrefix: rootName, add: add)
            } else if values.isRegularFile == true {
                try add(Entry(source: url, archivePath: rootName, isDirectory: false))
            } else {
                throw ZipServiceError.unsupportedItem(url.path)
            }
        }
        return entries
    }

    private func collectDirectory(
        _ directory: URL,
        archivePrefix: String,
        add: (Entry) throws -> Void
    ) throws {
        try checkCancellation()
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for child in children {
            try checkCancellation()
            let name = child.lastPathComponent
            guard !shouldSkip(name) else { continue }
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ZipServiceError.unsupportedItem(child.path)
            }
            let archivePath = archivePrefix + "/" + name
            if values.isDirectory == true {
                try add(Entry(source: nil, archivePath: archivePath + "/", isDirectory: true))
                try collectDirectory(child, archivePrefix: archivePath, add: add)
            } else if values.isRegularFile == true {
                try add(Entry(source: child, archivePath: archivePath, isDirectory: false))
            } else {
                throw ZipServiceError.unsupportedItem(child.path)
            }
        }
    }

    private func shouldSkip(_ name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    private func archiveNaming(inputs: [URL], now: Date) -> (fileName: String, subject: String) {
        if inputs.count == 1 {
            let input = inputs[0]
            let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let baseName = input.lastPathComponent
            return isDirectory ? (baseName + ".zip", baseName) : (input.deletingPathExtension().lastPathComponent + ".zip", baseName)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "Files_\(formatter.string(from: now)).zip"
        return (name, name)
    }

    private func writeArchive(_ entries: [Entry], to url: URL, password: String) throws {
        var openError: Int32 = 0
        let archive = url.path.withCString { path in
            zip_open(path, ZIP_CREATE | ZIP_EXCL, &openError)
        }
        guard let archive else {
            throw ZipServiceError.archiveCreation(zipErrorMessage(openError))
        }

        var needsDiscard = true
        defer {
            if needsDiscard {
                zip_discard(archive)
            }
        }

        for entry in entries {
            try checkCancellation()
            let index: zip_int64_t
            if entry.isDirectory {
                index = entry.archivePath.withCString {
                    zip_dir_add(archive, $0, ZIP_FL_ENC_UTF_8)
                }
            } else if let sourceURL = entry.source {
                let file = try openRegularFileWithoutFollowingLinks(sourceURL)
                guard let source = zip_source_filep(archive, file, 0, zip_int64_t(ZIP_LENGTH_TO_END)) else {
                    fclose(file)
                    throw ZipServiceError.archiveWrite(zipErrorMessage(zip_get_error(archive).pointee.zip_err))
                }
                let added = entry.archivePath.withCString { name in
                    zip_file_add(archive, name, source, ZIP_FL_ENC_UTF_8)
                }
                guard added >= 0 else {
                    zip_source_free(source)
                    throw ZipServiceError.archiveWrite(zipErrorMessage(zip_get_error(archive).pointee.zip_err))
                }
                let encrypted = password.withCString {
                    zip_file_set_encryption(archive, zip_uint64_t(added), zip_uint16_t(ZIP_EM_TRAD_PKWARE), $0)
                }
                guard encrypted == 0 else {
                    throw ZipServiceError.archiveWrite(zipErrorMessage(zip_get_error(archive).pointee.zip_err))
                }
                index = added
            } else {
                continue
            }
            guard index >= 0 else {
                throw ZipServiceError.archiveWrite(zipErrorMessage(zip_get_error(archive).pointee.zip_err))
            }
        }

        guard zip_close(archive) == 0 else {
            throw ZipServiceError.archiveWrite("libzip could not finalize the archive.")
        }
        needsDiscard = false
    }

    private func openRegularFileWithoutFollowingLinks(_ url: URL) throws -> UnsafeMutablePointer<FILE> {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw ZipServiceError.archiveWrite(
                "Could not safely open \(url.lastPathComponent): \(String(cString: strerror(errno)))."
            )
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            throw ZipServiceError.unsupportedItem(url.path)
        }
        guard let file = fdopen(descriptor, "rb") else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw ZipServiceError.archiveWrite("Could not read \(url.lastPathComponent): \(message)")
        }
        return file
    }

    private func validateArchive(at url: URL, password: String, expectedFiles: Int) throws {
        var openError: Int32 = 0
        let archive = url.path.withCString { path in
            zip_open(path, ZIP_RDONLY, &openError)
        }
        guard let archive else {
            throw ZipServiceError.archiveValidation(zipErrorMessage(openError))
        }
        defer { zip_discard(archive) }

        let count = zip_get_num_entries(archive, 0)
        guard count >= 0 else {
            throw ZipServiceError.archiveValidation("Could not read the archive directory.")
        }
        var verifiedFiles = 0
        for signedIndex in 0..<count {
            try checkCancellation()
            let index = zip_uint64_t(signedIndex)
            guard let name = zip_get_name(archive, index, ZIP_FL_ENC_GUESS) else {
                throw ZipServiceError.archiveValidation("An archive entry has an invalid name.")
            }
            let path = String(cString: name)
            guard !path.hasSuffix("/") else { continue }
            var stat = zip_stat_t()
            guard zip_stat_index(archive, index, ZIP_FL_ENC_GUESS, &stat) == 0,
                  stat.valid & zip_uint64_t(ZIP_STAT_ENCRYPTION_METHOD) != 0,
                  stat.encryption_method == zip_uint16_t(ZIP_EM_TRAD_PKWARE)
            else {
                throw ZipServiceError.archiveValidation("An entry is not encrypted with ZipCrypto.")
            }
            let file = zip_fopen_index_encrypted(archive, index, ZIP_FL_UNCHANGED, password)
            guard let file else {
                throw ZipServiceError.archiveValidation("An encrypted entry could not be opened.")
            }
            var needsClose = true
            defer {
                if needsClose { zip_fclose(file) }
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try checkCancellation()
                let bytesRead = buffer.withUnsafeMutableBufferPointer {
                    guard let baseAddress = $0.baseAddress else { return zip_int64_t(-1) }
                    return zip_fread(file, baseAddress, zip_uint64_t($0.count))
                }
                guard bytesRead >= 0 else {
                    throw ZipServiceError.archiveValidation("An archive entry failed its password or CRC check.")
                }
                if bytesRead == 0 { break }
            }
            let closeStatus = zip_fclose(file)
            needsClose = false
            guard closeStatus == 0 else {
                throw ZipServiceError.archiveValidation("An archive entry failed its CRC check.")
            }
            verifiedFiles += 1
        }
        guard verifiedFiles == expectedFiles else {
            throw ZipServiceError.archiveValidation("The archive entry count did not match the input files.")
        }
    }

    private func createPrivateDirectoryIfNeeded(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ZipServiceError.archiveWrite("The temporary workspace is not a private directory.")
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

    private func zipErrorMessage(_ code: Int32) -> String {
        var error = zip_error_t()
        zip_error_init_with_code(&error, code)
        defer { zip_error_fini(&error) }
        return String(cString: zip_error_strerror(&error))
    }
}
