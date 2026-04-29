import Foundation
import Security

/// Simple Keychain wrapper for storing API keys securely.
/// Keys are stored in the generic password keychain under service "com.abhishek.shiro".
enum KeychainHelper {

    private static let service = "com.abhishek.shiro"

    // MARK: - Known keys

    enum Key: String {
        case anthropicAPIKey   = "anthropic_api_key"
        case openAIAPIKey      = "openai_api_key"
        case openAIBaseURL     = "openai_base_url"
        case deepgramAPIKey    = "deepgram_api_key"
        case telegramBotToken  = "telegram_bot_token"
        case telegramChatId    = "telegram_chat_id"
        // MCP integration credentials — injected into the bridge subprocess env.
        case composioAPIKey    = "composio_api_key"
        case githubToken       = "github_personal_access_token"
        case huggingFaceToken  = "huggingface_token"
        // PageGrid — AI documentation search service
        case pagegridAPIKey    = "pagegrid_api_key"
    }

    // MARK: - Read / Write / Delete

    @discardableResult
    static func set(_ value: String, for key: Key) -> OSStatus {
        guard !value.isEmpty else { delete(key); return errSecSuccess }
        guard let data = value.data(using: .utf8) else {
            return errSecParam
        }

        // Try update first (preserves existing kSecAttrAccessible).
        let baseQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
        // Always include the accessibility attribute on update so upgrades
        // from a less-restrictive accessible class get re-locked.
        let updateAttrs: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess {
            return errSecSuccess
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData]      = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[KeychainHelper] SecItemAdd failed for \(key.rawValue): \(addStatus)")
            }
            return addStatus
        }

        print("[KeychainHelper] SecItemUpdate failed for \(key.rawValue): \(updateStatus)")
        return updateStatus
    }

    static func get(_ key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key.rawValue,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str  = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    static func delete(_ key: Key) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// True if a non-empty value exists for this key.
    static func has(_ key: Key) -> Bool { get(key) != nil }
}
