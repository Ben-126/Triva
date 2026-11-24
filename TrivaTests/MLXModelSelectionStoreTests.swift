//
//  MLXModelSelectionStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 06/09/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("MLXModelSelectionStore")
struct MLXModelSelectionStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `CloudProviderSelectionStoreTests.uniqueDefaults()`.
    private func uniqueDefaults() -> UserDefaults {
        TestDefaults.suite(named: "test.mlxModelSelectionStore.\(UUID().uuidString)")!
    }

    @Test("nil sans donnée stockée")
    func emptyWithoutStoredData() {
        let store = MLXModelSelectionStore(userDefaults: uniqueDefaults())
        #expect(store.selectedModelID == nil)
    }

    @Test("Persiste un id de modèle d'une instance à l'autre")
    func persistsAcrossInit() {
        let defaults = uniqueDefaults()
        let store = MLXModelSelectionStore(userDefaults: defaults)

        store.selectedModelID = "qwen3-1_7b-4bit"

        let reloaded = MLXModelSelectionStore(userDefaults: defaults)
        #expect(reloaded.selectedModelID == "qwen3-1_7b-4bit")
    }

    @Test("Écrase un id de modèle précédent")
    func overwritesPreviousSelection() {
        let defaults = uniqueDefaults()
        let store = MLXModelSelectionStore(userDefaults: defaults)
        store.selectedModelID = "qwen3-1_7b-4bit"

        store.selectedModelID = "qwen3-4b-4bit"

        let reloaded = MLXModelSelectionStore(userDefaults: defaults)
        #expect(reloaded.selectedModelID == "qwen3-4b-4bit")
    }

    @Test("Effacer la sélection (nil) est bien persisté")
    func clearingSelectionPersists() {
        let defaults = uniqueDefaults()
        let store = MLXModelSelectionStore(userDefaults: defaults)
        store.selectedModelID = "qwen3-1_7b-4bit"

        store.selectedModelID = nil

        let reloaded = MLXModelSelectionStore(userDefaults: defaults)
        #expect(reloaded.selectedModelID == nil)
    }

    @Test("« Plusieurs modèles en mémoire » : éteint par défaut")
    func multipleModelsOffByDefault() {
        let store = MLXModelSelectionStore(userDefaults: uniqueDefaults())
        #expect(store.allowsMultipleModels == false)
    }

    @Test("« Plusieurs modèles en mémoire » : allumé puis éteint, chaque état est persisté, sans toucher au modèle choisi")
    func multipleModelsSettingPersists() {
        let defaults = uniqueDefaults()
        let store = MLXModelSelectionStore(userDefaults: defaults)
        store.selectedModelID = "qwen3-4b-4bit"

        store.allowsMultipleModels = true
        #expect(MLXModelSelectionStore(userDefaults: defaults).allowsMultipleModels == true)

        store.allowsMultipleModels = false
        let reloaded = MLXModelSelectionStore(userDefaults: defaults)
        #expect(reloaded.allowsMultipleModels == false)
        #expect(reloaded.selectedModelID == "qwen3-4b-4bit")
    }
}
