import Foundation
import Security

/// Connection passwords, stored as generic passwords in the login Keychain.
/// Each item's account is the connection's UUID, so renaming a connection keeps its password.
///
/// Reading a password is what makes macOS ask for permission, so each one is read at most once per launch
/// and then kept in memory. "Always Allow" lasts across updates because the app is signed with the same
/// certificate each time (see scripts/build-app.sh); an ad-hoc signature changes with every build.
@MainActor
enum Keychain {
    private static let service = "uk.co.llexeter.mysqldesk"
    private static var cache: [UUID: String] = [:]

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
        if let cached = cache[id] { return cached }
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        cache[id] = password
        return password
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
        if status == errSecSuccess {
            cache[id] = password
            return true
        }
        guard status == errSecItemNotFound else { return false }

        var add = query(id)
        add.merge(update) { $1 }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        cache[id] = password
        return true
    }

    static func deletePassword(for id: UUID) {
        cache[id] = nil
        SecItemDelete(query(id) as CFDictionary)
    }
}
