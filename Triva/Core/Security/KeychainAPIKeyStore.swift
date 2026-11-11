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

    /// Lecture qui ne doit PAS tenir le fil principal. `apiKey(account:)` est isolée au
    /// main actor (comme tout ce protocole) : sur Mac, une invite d'autorisation du
    /// trousseau la bloque tant qu'elle est ouverte, et l'écran gèle avec elle.
    /// Les écrans qui lisent beaucoup de clés d'un coup (`CloudProviderModelPickerViewModel`)
    /// passent par celle-ci. Défaut : saute sur le main actor et appelle `apiKey(account:)`,
    /// ce qui garde le comportement des faux magasins de test ; `KeychainAPIKeyStore`
    /// la surcharge avec une vraie lecture hors main actor.
    nonisolated func readAPIKey(account: String) async throws -> String?
}

extension APIKeyStoring {
    nonisolated func readAPIKey(account: String) async throws -> String? {
        try await MainActor.run { try apiKey(account: account) }
    }
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
        try Self.copyAPIKey(service: service, account: account)
    }

    /// Lecture réelle hors du main actor : `@concurrent` est indispensable, une
    /// fonction `nonisolated async` s'exécuterait sinon sur l'acteur de l'appelant
    /// (voir CLAUDE.md, section concurrence). Sert à `CloudProviderModelPickerViewModel`.
    @concurrent
    func readAPIKey(account: String) async throws -> String? {
        try Self.copyAPIKey(service: service, account: account)
    }

    /// `SecItemCopyMatching` seul, sans état : appelable de n'importe quel contexte.
    nonisolated private static func copyAPIKey(service: String, account: String) throws -> String? {
        var query = query(service: service, account: account)
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
        let query = baseQuery(account: account)

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
        Self.query(service: service, account: account)
    }

    nonisolated private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }
}
