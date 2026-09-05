//
//  CustomProviderStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("CustomProviderStore")
struct CustomProviderStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `KeychainAPIKeyStoreTests.uniqueService()`.
    private func uniqueDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.customProviderStore.\(UUID().uuidString)")!
    }

    @Test("Vide sans données stockées")
    func emptyWithoutStoredData() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults())
        #expect(store.customPresets.isEmpty)
    }

    @Test("Ajoute un fournisseur personnalisé et le rend disponible immédiatement")
    func addMakesPresetAvailableImmediately() {
        let store = CustomProviderStore(userDefaults: uniqueDefaults())

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
        let store = CustomProviderStore(userDefaults: defaults)
        let added = store.add(
            displayName: "Mon LLM maison",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )

        let reloaded = CustomProviderStore(userDefaults: defaults)

        #expect(reloaded.customPresets.contains(added))
    }

    @Test("Supprime un fournisseur personnalisé")
    func removeDeletesEntry() {
        let defaults = uniqueDefaults()
        let store = CustomProviderStore(userDefaults: defaults)
        let added = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "m"
        )

        store.remove(id: added.id)

        #expect(!store.customPresets.contains(added))
        #expect(CustomProviderStore(userDefaults: defaults).customPresets.isEmpty)
    }
}
