import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case unusableData
}

/// 厂商密钥的唯一存放处。
///
/// 用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：设备解锁后可用、不随备份迁移。
/// 密钥绝不进 SQLite、UserDefaults 或日志。
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "local.igent") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func set(_ value: String, for account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    public func get(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary) == errSecSuccess
    }

    /// 密钥的存储键：按 profile id 隔离，换厂商不用互删。
    public static func account(for profileID: String) -> String {
        "provider.\(profileID)"
    }
}
