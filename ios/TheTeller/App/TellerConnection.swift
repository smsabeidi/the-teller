import Foundation
import Security

struct TellerConnection: Codable, Equatable {
    let baseURL: URL
    let accessKey: String?

    static func supplied(address: String, key: String) throws -> Self {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address), let url = parts.url, let host = parts.host,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw ConnectionError.invalidAddress
        }
        let loopback = ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
        if parts.scheme != "https" {
            #if DEBUG
            guard parts.scheme == "http", loopback else { throw ConnectionError.requiresHTTPS }
            #else
            throw ConnectionError.requiresHTTPS
            #endif
        }
        if key.isEmpty && !loopback { throw ConnectionError.needsKey }
        if !key.isEmpty && key.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) == nil {
            throw ConnectionError.invalidKey
        }
        return Self(baseURL: url, accessKey: key.isEmpty ? nil : key)
    }

    static func restore() -> Self? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.keychainQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.storage }
        } else if status != errSecSuccess {
            throw ConnectionError.storage
        }
    }

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.smsabeidi.theteller.connection",
        kSecAttrAccount as String: "personal-backend"
    ]
}

enum ConnectionError: LocalizedError {
    case invalidAddress, requiresHTTPS, needsKey, invalidKey, storage

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter the server origin, for example https://teller.example.com."
        case .requiresHTTPS: "Use the HTTPS address of your personal server."
        case .needsKey: "Enter your personal server key."
        case .invalidKey: "The server key should contain 32–128 letters, numbers, dashes, or underscores."
        case .storage: "The connection could not be saved in Keychain."
        }
    }
}
