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

    func apiKey(account: String) throws -> String? { storedKeysByAccount[account] }

    func save(apiKey: String, account: String) throws {
        storedKeysByAccount[account] = apiKey
    }

    func deleteAPIKey(account: String) throws {
        deletedAccounts.append(account)
        storedKeysByAccount[account] = nil
    }
}

@Suite("CustomProviderStore")
struct CustomProviderStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `KeychainAPIKeyStoreTests.uniqueService()`.
    private func uniqueDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.customProviderStore.\(UUID().uuidString)")!
    }

    /// `UserDefaults` isolé par test — jamais `.standard`, pour ne pas
    /// toucher une vraie sélection persistée sur la machine qui exécute les
    /// tests (`remove(id:)` peut l'effacer, voir tests dédiés plus bas).
    private func uniqueSelectionStore() -> CloudProviderSelectionStore {
        CloudProviderSelectionStore(userDefaults: UserDefaults(suiteName: "test.customProviderStore.selection.\(UUID().uuidString)")!)
    }

    @Test("Vide sans données stockées")
    func emptyWithoutStoredData() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: uniqueSelectionStore())
        #expect(store.customPresets.isEmpty)
    }

    @Test("Ajoute un fournisseur personnalisé et le rend disponible immédiatement")
    func addMakesPresetAvailableImmediately() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: uniqueSelectionStore())

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
        let store = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore())
        let added = store.add(
            displayName: "Mon LLM maison",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )

        let reloaded = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore())

        #expect(reloaded.customPresets.contains(added))
    }

    @Test("Supprime un fournisseur personnalisé")
    func removeDeletesEntry() {
        let defaults = uniqueDefaults()
        let store = CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore())
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )

        store.remove(id: added.id)

        #expect(!store.customPresets.contains(added))
        #expect(CustomProviderStore(userDefaults: defaults, selectionStore: uniqueSelectionStore()).customPresets.isEmpty)
    }

    @Test("Supprimer le fournisseur personnalisé actuellement sélectionné efface aussi la sélection")
    func removingSelectedPresetClearsSelection() {
        let selectionStore = uniqueSelectionStore()
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: selectionStore)
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
        selectionStore.selection = CloudProviderSelection(providerID: added.id, model: "m")

        store.remove(id: added.id)

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

        store.remove(id: added.id)

        #expect(keyStore.deletedAccounts == [added.id])
        #expect(try keyStore.apiKey(account: added.id) == nil)
    }

    @Test("Supprimer un fournisseur personnalisé non sélectionné laisse la sélection intacte")
    func removingOtherPresetKeepsSelection() {
        let selectionStore = uniqueSelectionStore()
        let store = CustomProviderStore(userDefaults: uniqueDefaults(), selectionStore: selectionStore)
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )
        selectionStore.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")

        store.remove(id: added.id)

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5"))
    }
}
