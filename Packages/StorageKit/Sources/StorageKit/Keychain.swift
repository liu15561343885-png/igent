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
        let data = Data(value.utf8)

        // 先试更新：旧实现是"删除 + 新增"，新增失败时原来的 Key 就没了，
        // 而调用方只会看到"保存失败"，其实已经丢了凭据。
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
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
