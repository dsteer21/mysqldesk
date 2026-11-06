import Foundation
import Security

/// Connection passwords, stored as generic passwords in the login Keychain.
/// Each item's account is the connection's UUID, so renaming a connection keeps its password.
enum Keychain {
    private static let service = "uk.co.llexeter.mysqldesk"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func password(for id: UUID) -> String? {
        #if DEBUG
        if let password = ProcessInfo.processInfo.environment["MYSQLDESK_TEST_PASSWORD"] { return password }
        #endif
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a password is saved, without reading it. Reading the secret is what makes macOS ask
    /// for permission, so this is safe to call just to show "Saved in Keychain".
    static func hasPassword(for id: UUID) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYSQLDESK_TEST_PASSWORD"] != nil { return true }
        #endif
        var query = query(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func setPassword(_ password: String, for id: UUID, label: String) -> Bool {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "MysqlDesk: \(label)"]
        let status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var add = query(id)
        add.merge(update) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
