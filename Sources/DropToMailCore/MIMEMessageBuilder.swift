import Foundation

public struct MIMEMessageBuilder: Sendable {
    // Conservative application limits. Workspace policy can impose a lower limit.
    public static let maximumAttachmentBytes = 25_000_000
    public static let maximumMessageBytes = 35_000_000

    public init() {}

    public func build(archive: PreparedArchive, sender: String, recipient: String, now: Date = Date()) throws -> Data {
        try Task.checkCancellation()
        let sender = sender.trimmingCharacters(in: .whitespaces)
        let recipient = recipient.trimmingCharacters(in: .whitespaces)
        guard AppSettings.isValidEmail(sender), AppSettings.isValidEmail(recipient) else { throw GmailError.invalidAddress }
        guard safeHeaderText(archive.subject), safeHeaderText(archive.fileName), !archive.fileName.isEmpty else {
            throw GmailError.invalidHeader
        }
        let attributes: URLResourceValues
        do { attributes = try archive.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw GmailError.attachmentRead }
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size >= 0 else { throw GmailError.attachmentRead }
        guard size <= Self.maximumAttachmentBytes else { throw GmailError.messageTooLarge }

        let boundary = "DropToMail_" + UUID().uuidString
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = sender.split(separator: "@")[1]
        var message = Data(([
            "From: \(sender)",
            "To: \(recipient)",
            "Subject: \(encodedSubject(archive.subject))",
            "Date: \(date.string(from: now))",
            "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "", "--\(boundary)",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 7bit",
            "", "", "--\(boundary)",
            "Content-Type: application/zip",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment;",
            filenameParameters(archive.fileName), "", ""
        ].joined(separator: "\r\n")).utf8)

        // Read bounded chunks, so cancellation and a file growing beyond the limit are detected.
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archive.fileURL) }
        catch { throw GmailError.attachmentRead }
        defer { try? handle.close() }
        var bytesRead = 0
        var attachmentBuffer = Data()
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do { chunk = try handle.read(upToCount: 57 * 1024) ?? Data() }
            catch { throw GmailError.attachmentRead }
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            guard bytesRead <= Self.maximumAttachmentBytes else { throw GmailError.messageTooLarge }
            // 57 bytes make one 76-character MIME base64 line. FileHandle may return short reads.
            // Accumulate any partial line before encoding to avoid base64 padding mid-part.
            attachmentBuffer.append(chunk)
            let completeBytes = (attachmentBuffer.count / 57) * 57
            if completeBytes > 0 {
                message.append(attachmentBuffer.prefix(completeBytes).base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
                message.append(Data("\r\n".utf8))
                attachmentBuffer.removeFirst(completeBytes)
            }
            guard message.count <= Self.maximumMessageBytes else { throw GmailError.messageTooLarge }
        }
        if !attachmentBuffer.isEmpty {
            message.append(attachmentBuffer.base64EncodedData())
            message.append(Data("\r\n".utf8))
        }
        guard bytesRead == size else { throw GmailError.attachmentRead }
        message.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard message.count <= Self.maximumMessageBytes else { throw GmailError.messageTooLarge }
        try Task.checkCancellation()
        return message
    }

    private func safeHeaderText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    private func encodedSubject(_ subject: String) -> String {
        // Each encoded word is <= 68 ASCII characters and contains complete UTF-8 scalars.
        var words: [String] = []
        var bytes = Data()
        for scalar in subject.unicodeScalars {
            let next = Data(String(scalar).utf8)
            if bytes.count + next.count > 42 {
                words.append("=?UTF-8?B?\(bytes.base64EncodedString())?=")
                bytes = Data()
            }
            bytes.append(next)
        }
        if !bytes.isEmpty { words.append("=?UTF-8?B?\(bytes.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    private func filenameParameters(_ name: String) -> String {
        let bytes = Array(name.utf8)
        var parts: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let value = bytes[offset..<min(offset + 16, bytes.count)].map { String(format: "%%%02X", $0) }.joined()
            let index = offset / 16
            let prefix = index == 0 ? "UTF-8''" : ""
            parts.append(" filename*\(index)*=\(prefix)\(value)")
        }
        return parts.joined(separator: ";\r\n")
    }
}
