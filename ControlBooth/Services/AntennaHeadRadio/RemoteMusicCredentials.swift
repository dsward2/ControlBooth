import Foundation
import Security

/// The password for AntennaHead Radio's remote music Mac, kept in the login
/// Keychain (never in the station settings), one item per user@host.
nonisolated enum RemoteMusicCredentials {
    private static let service = "com.dsward.ControlBooth.AntennaHeadRadio.remoteMusic"

    private static func account(user: String, host: String) -> String {
        "\(user)@\(host.lowercased())"
    }

    static func password(user: String, host: String) -> String? {
        guard !user.isEmpty, !host.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(user: user, host: host),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves (or, for an empty password, removes) the item.
    @discardableResult
    static func setPassword(_ password: String, user: String, host: String) -> Bool {
        guard !user.isEmpty, !host.isEmpty else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(user: user, host: host),
        ]
        guard !password.isEmpty else {
            let status = SecItemDelete(match as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "AntennaHead Radio music Mac (\(host))"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
