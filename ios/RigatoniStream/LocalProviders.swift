import Foundation
import Security

// Provider logins saved on this device. This is separate from the Supabase
// session item: session tokens stay in SessionKeychain, and these credentials
// never go to UserDefaults, logs, or disk caches.
struct LocalProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var server: String
    var username: String
    var password: String
    var gateway: String

    var hostLabel: String {
        URL(string: server)?.host ?? "Provider"
    }
    var displayName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? hostLabel : label
    }

    static func make(id: String, name: String, provider: Provider, gateway: String) throws -> LocalProvider {
        let base = try provider.baseURL()
        let origin = try AccountAPI.gatewayOrigin(gateway)
        let server = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalProvider(
            id: id,
            name: String(label.prefix(60)),
            server: server,
            username: provider.username,
            password: provider.password,
            gateway: origin
        )
    }
}

struct LocalProviderVault: Codable, Equatable {
    static let limit = 12
    var activeID: String?
    var providers: [LocalProvider] = []
}

enum ProviderKeychain {
    static let service = "com.acasso01.rigatonistream.providers"
    static let account = "local-providers"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func read() throws -> LocalProviderVault {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return LocalProviderVault() }
        guard code == errSecSuccess, let data = result as? Data else {
            throw AppFailure("The provider saved on this device could not be read.")
        }
        // An unreadable payload is treated as empty so a new save can replace it.
        // The error text never includes the stored bytes.
        guard let vault = try? JSONDecoder().decode(LocalProviderVault.self, from: data) else {
            return LocalProviderVault()
        }
        return vault
    }

    static func write(_ store: LocalProviderVault) throws {
        let data = try JSONEncoder().encode(store)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let code = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if code == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw AppFailure("Could not save the provider on this device.")
            }
        } else if code != errSecSuccess {
            throw AppFailure("Could not update the provider saved on this device.")
        }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }

    /// Keychain attributes for tests. Nil when nothing is stored.
    static func attributes() throws -> [String: Any]? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let attrs = result as? [String: Any] else {
            throw AppFailure("The provider saved on this device could not be read.")
        }
        return attrs
    }
}

enum GatewayAccess {
    /// Gateway catalog and playback need an account session. Direct providers do not.
    static let signInMessage = "Sign in to your Ant Streams account to use the HTTPS gateway. Direct providers work without an account."
}
