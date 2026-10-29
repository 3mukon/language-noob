import Foundation
import Security
import LocalAuthentication

public protocol AssistantKeyStoring: Sendable {
    func key(for configuration: AssistantConfiguration) throws -> String?
    func contains(_ configuration: AssistantConfiguration) throws -> Bool
    func save(_ key: String, for configuration: AssistantConfiguration) throws
    func remove(_ configuration: AssistantConfiguration) throws
}

/// Values stay in the native transport and never enter ordinary settings or the bridge.
public struct AssistantKeyStore: AssistantKeyStoring {
    public init() {}
    private func query(_ configuration: AssistantConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.language-noob.assistant-api",
         kSecAttrAccount as String: try configuration.keyAccount(),
         kSecAttrSynchronizable as String: false]
    }
    public func key(for configuration: AssistantConfiguration) throws -> String? {
        var query = try query(configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw AssistantError.keyStore }
        return key
    }
    public func contains(_ configuration: AssistantConfiguration) throws -> Bool {
        var query = try query(configuration)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AssistantError.keyStore }
        return true
    }
    public func save(_ key: String, for configuration: AssistantConfiguration) throws {
        try Self.validate(key)
        let query = try query(configuration), data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AssistantError.keyStore }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AssistantError.keyStore }
    }
    public func remove(_ configuration: AssistantConfiguration) throws {
        let status = SecItemDelete(try query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.keyStore }
    }
    static func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AssistantError.missingKey }
    }
}
