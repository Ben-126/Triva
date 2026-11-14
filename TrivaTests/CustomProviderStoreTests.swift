//
//  CustomProviderStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux magasin de clés API, pour vérifier que `remove(id:)` nettoie bien le
/// Keychain sans toucher au vrai trousseau de la machine qui exécute les
/// tests.
private final class MockAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private(set) var deletedAccounts: [String] = []
    var storedKeysByAccount: [String: String] = [:]
    /// Erreur à lever à chaque suppression (Trousseau en panne), `nil` = tout va bien.
    var deleteError: (any Error)?

    func apiKey(account: String) throws -> String? { storedKeysByAccount[account] }

    func save(apiKey: String, account: String) throws {
        storedKeysByAccount[account] = apiKey
    }

    func deleteAPIKey(account: String) throws {
        if let deleteError { throw deleteError }
        deletedAccounts.append(account)
        storedKeysByAccount[account] = nil
    }
}

@MainActor
@Suite("CustomProviderStore")
struct CustomProviderStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `KeychainAPIKeyStoreTests.uniqueService()`.
    private func uniqueDefaults() -> UserDefaults {
        TestDefaults.suite(named: "test.customProviderStore.\(UUID().uuidString)")!
    }

    /// `UserDefaults` isolé par test — jamais `.standard`, pour ne pas
    /// toucher une vraie sélection persistée sur la machine qui exécute les
    /// tests (`remove(id:)` peut l'effacer, voir tests dédiés plus bas).
    private func uniqueSelectionStore() -> CloudProviderSelectionStore {
        CloudProviderSelectionStore(userDefaults: TestDefaults.suite(named: "test.customProviderStore.selection.\(UUID().uuidString)")!)
    }

    @Test("Vide sans données stockées")
    func emptyWithoutStoredData() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore())
        #expect(store.customPresets.isEmpty)
    }

    @Test("Ajoute un fournisseur personnalisé et le rend disponible immédiatement")
    func addMakesPresetAvailableImmediately() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore())

        let added = store.add(
            displayName: "Mon LLM maison",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )

        #expect(store.customPresets.contains(added))
        #expect(added.displayName == "Mon LLM maison")
    }

    @Test("Persiste les fournisseurs personnalisés d'une instance à l'autre")
    func addPersistsAcrossInit() {
        let defaults = uniqueDefaults()
        let store = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore())
        let added = store.add(
            displayName: "Mon LLM maison",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )

        let reloaded = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore())

        #expect(reloaded.customPresets.contains(added))
    }

    @Test("Supprime un fournisseur personnalisé")
    func removeDeletesEntry() throws {
        let defaults = uniqueDefaults()
        let store = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore())
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )

        try store.remove(id: added.id)

        #expect(!store.customPresets.contains(added))
        #expect(CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore(), keyStore: MockAPIKeyStore()).customPresets.isEmpty)
    }

    @Test("Supprimer le fournisseur personnalisé actuellement sélectionné efface aussi la sélection")
    func removingSelectedPresetClearsSelection() throws {
        let selectionStore = uniqueSelectionStore()
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: selectionStore, keyStore: MockAPIKeyStore())
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
        selectionStore.selection = CloudProviderSelection(providerID: added.id, model: "m")

        try store.remove(id: added.id)

        #expect(selectionStore.selection == nil)
    }

    @Test("Supprimer un fournisseur personnalisé efface aussi sa clé API du Keychain")
    func removeDeletesKeychainEntry() throws {
        let keyStore = MockAPIKeyStore()
        let store = CustomProviderStore(
            userDefaults: uniqueDefaults(),
            selectionStore: uniqueSelectionStore(),
            keyStore: keyStore
        )
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
        try? keyStore.save(apiKey: "secret", account: added.id)

        try store.remove(id: added.id)

        #expect(keyStore.deletedAccounts == [added.id])
        #expect(try keyStore.apiKey(account: added.id) == nil)
    }

    @Test("Supprimer un fournisseur personnalisé non sélectionné laisse la sélection intacte")
    func removingOtherPresetKeepsSelection() throws {
        let selectionStore = uniqueSelectionStore()
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: selectionStore, keyStore: MockAPIKeyStore())
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
        selectionStore.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")

        try store.remove(id: added.id)

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5"))
    }

    // MARK: - Échec du Trousseau (K5)

    @Test("Le Trousseau refuse de supprimer la clé : l'erreur remonte, le fournisseur et la sélection restent en place")
    func failedKeyDeletionKeepsTheProviderAndTheSelection() throws {
        let keyStore = MockAPIKeyStore()
        keyStore.deleteError = KeychainAPIKeyStoreError.unexpectedStatus(-25293)
        let selectionStore = uniqueSelectionStore()
        let defaults = uniqueDefaults()
        let store = CustomProviderStore(userDefaults: defaults, selectionStore: selectionStore, keyStore: keyStore)
        let added = store.add(displayName: "Mon LLM", baseURL: URL(string: "https://llm.example.com/v1")!, model: "m")
        let selection = CloudProviderSelection(providerID: added.id, model: "m")
        selectionStore.selection = selection
        try keyStore.save(apiKey: "secret", account: added.id)

        #expect(throws: CustomProviderStoreError.keyNotDeleted) {
            try store.remove(id: added.id)
        }

        #expect(store.customPresets == [added])
        #expect(selectionStore.selection == selection)
        #expect(try keyStore.apiKey(account: added.id) == "secret")
        // Rien n'a été persisté non plus : au prochain lancement, le fournisseur est toujours là.
        #expect(CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore(), keyStore: keyStore)
            .customPresets == [added])
    }

    @Test("Une fois le Trousseau rétabli, la même suppression réussit")
    func retryingAfterAKeychainFailureSucceeds() throws {
        let keyStore = MockAPIKeyStore()
        keyStore.deleteError = KeychainAPIKeyStoreError.unexpectedStatus(-25293)
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: uniqueSelectionStore(), keyStore: keyStore)
        let added = store.add(displayName: "Mon LLM", baseURL: URL(string: "https://llm.example.com/v1")!, model: "m")
        #expect(throws: CustomProviderStoreError.keyNotDeleted) { try store.remove(id: added.id) }

        keyStore.deleteError = nil
        try store.remove(id: added.id)

        #expect(store.customPresets.isEmpty)
    }
}
