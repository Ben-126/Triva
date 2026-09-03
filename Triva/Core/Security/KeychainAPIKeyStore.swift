//
//  KeychainAPIKeyStore.swift
//  Triva
//
//  Created by ben podrojsky on 31/08/2026.
//

import Foundation
import Security

/// Accès à une clé API BYOK (0.6), pour pouvoir injecter un faux magasin
/// dans les tests sans toucher au vrai Keychain de l'appareil.
protocol APIKeyStoring: Sendable {
    func apiKey(account: String) throws -> String?
    func save(apiKey: String, account: String) throws
    func deleteAPIKey(account: String) throws
}

enum KeychainAPIKeyStoreError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Stocke les clés API BYOK (Claude, puis d'autres fournisseurs cloud le cas
/// échéant) exclusivement en Keychain local — jamais en UserDefaults ni en
/// clair sur disque, conformément à la règle BYOK du projet (zéro serveur
/// intermédiaire, la clé ne doit jamais quitter l'appareil).
struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String

    init(service: String = "com.benpodrojsky.Triva.cloudBYOK") {
        self.service = service
    }

    func apiKey(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    func save(apiKey: String, account: String) throws {
        let data = Data(apiKey.utf8)
        var query = baseQuery(account: account)

        let addStatus = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(addStatus)
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(updateStatus)
        }
    }

    func deleteAPIKey(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
