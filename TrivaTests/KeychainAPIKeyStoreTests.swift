//
//  KeychainAPIKeyStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/08/2026.
//

import Testing
import Foundation
@testable import Triva

/// Un `service` Keychain unique par test évite toute interférence entre
/// tests exécutés en parallèle ou d'une exécution à l'autre.
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

    private func uniqueService() -> String {
        "com.benpodrojsky.Triva.tests.\(UUID().uuidString)"
    }
}
