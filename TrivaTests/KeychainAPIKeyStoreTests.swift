//
//  KeychainAPIKeyStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/08/2026.
//

import Testing
import Foundation
import Security
@testable import Triva

/// Un `service` Keychain unique par test évite toute interférence entre
/// tests exécutés en parallèle ou d'une exécution à l'autre.
@MainActor
@Suite("KeychainAPIKeyStore")
struct KeychainAPIKeyStoreTests {
    @Test("Round-trip : save() puis apiKey() renvoie la même valeur")
    func saveThenRead() throws {
        let store = KeychainAPIKeyStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-test-123", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-test-123")
    }

    @Test("apiKey() renvoie nil quand rien n'est stocké")
    func readWithoutStoredKeyReturnsNil() throws {
        let store = KeychainAPIKeyStore(service: uniqueService())

        #expect(try store.apiKey(account: "claude") == nil)
    }

    @Test("readAPIKey() (lecture hors main actor) renvoie la même valeur que apiKey()")
    func offMainReadMatchesSyncRead() async throws {
        let store = KeychainAPIKeyStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        #expect(try await store.readAPIKey(account: "claude") == nil)
        try store.save(apiKey: "sk-test-456", account: "claude")

        #expect(try await store.readAPIKey(account: "claude") == "sk-test-456")
    }

    @Test("save() écrase une clé existante pour le même compte")
    func saveOverwritesExistingKey() throws {
        let store = KeychainAPIKeyStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-old", account: "claude")
        try store.save(apiKey: "sk-new", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-new")
    }

    @Test("deleteAPIKey() supprime la clé stockée")
    func deleteRemovesKey() throws {
        let store = KeychainAPIKeyStore(service: uniqueService())

        try store.save(apiKey: "sk-test", account: "claude")
        try store.deleteAPIKey(account: "claude")

        #expect(try store.apiKey(account: "claude") == nil)
    }

    @Test("deleteAPIKey() ne lève pas d'erreur si rien n'est stocké")
    func deleteWithoutStoredKeyDoesNotThrow() throws {
        let store = KeychainAPIKeyStore(service: uniqueService())

        try store.deleteAPIKey(account: "claude")
    }

#if os(macOS)
    // MARK: - Migration de l'ancien trousseau Mac vers le trousseau protégé (mission C2)

    @Test("Mac : une clé de l'ancien trousseau est copiée dans le trousseau protégé, l'ancienne reste", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func legacyKeyIsCopiedAndKept() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = KeychainAPIKeyStore(service: service, migrationFlagsSuite: flags)
        defer { try? store.deleteAPIKey(account: "claude") }

        #expect(try store.apiKey(account: "claude") == "sk-legacy")
        // Copiée dans le trousseau protégé, et l'ancienne entrée n'a pas été supprimée.
        #expect(try readProtected(service: service, account: "claude") == "sk-legacy")
        #expect(try readLegacy(service: service, account: "claude") == "sk-legacy")
    }

    @Test("Mac : une clé supprimée dans Triva ne renaît pas depuis l'ancien trousseau, qui n'est pas touché", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func deletedKeyDoesNotComeBack() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = KeychainAPIKeyStore(service: service, migrationFlagsSuite: flags)

        #expect(try store.apiKey(account: "claude") == "sk-legacy")
        try store.deleteAPIKey(account: "claude")

        #expect(try store.apiKey(account: "claude") == nil)
        #expect(try readLegacy(service: service, account: "claude") == "sk-legacy")
    }

    @Test("Mac : une clé enregistrée dans Triva l'emporte sur l'ancienne, sans la modifier", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func savedKeyShadowsLegacy() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = KeychainAPIKeyStore(service: service, migrationFlagsSuite: flags)
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-new", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-new")
        #expect(try readLegacy(service: service, account: "claude") == "sk-legacy")
    }

    @Test("Mac : migrateLegacyKeys() copie tous les comptes du service, hors du fil principal", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func migrateLegacyKeysCopiesEveryAccount() async throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer {
            removeLegacy(service: service, account: "openai")
            removeLegacy(service: service, account: "groq")
        }
        try addLegacy("sk-openai", service: service, account: "openai")
        try addLegacy("sk-groq", service: service, account: "groq")
        let store = KeychainAPIKeyStore(service: service, migrationFlagsSuite: flags)
        defer {
            try? store.deleteAPIKey(account: "openai")
            try? store.deleteAPIKey(account: "groq")
        }

        let failed = await store.migrateLegacyKeys()

        #expect(failed.isEmpty)
        #expect(try readProtected(service: service, account: "openai") == "sk-openai")
        #expect(try readProtected(service: service, account: "groq") == "sk-groq")
        #expect(try readLegacy(service: service, account: "openai") == "sk-openai")
    }

    @Test("Mac : sans ancienne clé, la lecture renvoie nil et ne crée rien", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func nothingToMigrateReturnsNil() throws {
        let service = uniqueService()
        let store = KeychainAPIKeyStore(service: service, migrationFlagsSuite: freshFlags())

        #expect(try store.apiKey(account: "claude") == nil)
        #expect(try readProtected(service: service, account: "claude") == nil)
    }

    // MARK: Aides : accès direct aux deux trousseaux, hors du code testé

    /// Suite `UserDefaults` neuve par test pour les drapeaux de migration (jamais la standard).
    private func freshFlags() -> String {
        "triva.tests.keychainFlags.\(UUID().uuidString)"
    }

    private func legacyQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func addLegacy(_ key: String, service: String, account: String) throws {
        var query = legacyQuery(service: service, account: account)
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainAPIKeyStoreError.unexpectedStatus(status) }
    }

    private func removeLegacy(service: String, account: String) {
        SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
    }

    private func readLegacy(service: String, account: String) throws -> String? {
        try read(legacyQuery(service: service, account: account))
    }

    private func readProtected(service: String, account: String) throws -> String? {
        var query = legacyQuery(service: service, account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        return try read(query)
    }

    private func read(_ base: [String: Any]) throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }
#endif

    private func uniqueService() -> String {
        "com.benpodrojsky.Triva.tests.\(UUID().uuidString)"
    }
}
