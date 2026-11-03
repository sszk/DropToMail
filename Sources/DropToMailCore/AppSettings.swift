import Foundation

public enum AppSettings {
    public static let countdownValues = [0, 5, 10, 30, 60]
    public static let defaultCountdown = 10
    public static let recipientKey = "recipientAddress"
    public static let floatingWindowKey = "floatingWindow"
    public static let countdownKey = "countdownSeconds"

    public static func isValidEmail(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespaces)
        guard candidate.utf8.count <= 254, candidate.allSatisfy({ $0.isASCII }),
              !candidate.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        let localCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~")
        guard parts[0].unicodeScalars.allSatisfy({ localCharacters.contains($0) }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        let domainCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.count >= 2 && labels.allSatisfy {
            !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.unicodeScalars.allSatisfy { domainCharacters.contains($0) }
        }
    }
}
