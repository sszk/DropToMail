import Foundation
import Security

public enum KeychainService {
    private static let service = "com.example.DropToMail"

    public static func readPassword() throws -> String? {
        let data = try readData(account: "zip-password")
        guard let data else { return nil }
        guard let password = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return password
    }

    static func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
        guard let data = result as? Data
        else {
            throw KeychainError.invalidData
        }
        return data
    }

    public static func savePassword(_ password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try saveData(data, account: "zip-password")
    }

    static func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError.status(insertStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public static func deletePassword() throws {
        try deleteData(account: "zip-password")
    }

    static func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            return "Keychain error (\(status))."
        case .invalidData:
            return "The stored Keychain data could not be read."
        }
    }
}
