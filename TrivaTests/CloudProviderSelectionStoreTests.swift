//
//  CloudProviderSelectionStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("CloudProviderSelectionStore")
struct CloudProviderSelectionStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `CustomProviderStoreTests.uniqueDefaults()`.
    private func uniqueDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.cloudProviderSelectionStore.\(UUID().uuidString)")!
    }

    @Test("nil sans donnée stockée")
    func emptyWithoutStoredData() {
        let store = CloudProviderSelectionStore(userDefaults: uniqueDefaults())
        #expect(store.selection == nil)
    }

    @Test("Persiste une sélection d'une instance à l'autre")
    func persistsAcrossInit() {
        let defaults = uniqueDefaults()
        let store = CloudProviderSelectionStore(userDefaults: defaults)
        let selection = CloudProviderSelection(providerID: "groq", model: "llama-3.3-70b-versatile")

        store.selection = selection

        let reloaded = CloudProviderSelectionStore(userDefaults: defaults)
        #expect(reloaded.selection == selection)
    }

    @Test("Écrase une sélection précédente")
    func overwritesPreviousSelection() {
        let defaults = uniqueDefaults()
        let store = CloudProviderSelectionStore(userDefaults: defaults)
        store.selection = CloudProviderSelection(providerID: "groq", model: "llama-3.3-70b-versatile")

        let newSelection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        store.selection = newSelection

        let reloaded = CloudProviderSelectionStore(userDefaults: defaults)
        #expect(reloaded.selection == newSelection)
    }

    @Test("Effacer la sélection (nil) est bien persisté")
    func clearingSelectionPersists() {
        let defaults = uniqueDefaults()
        let store = CloudProviderSelectionStore(userDefaults: defaults)
        store.selection = CloudProviderSelection(providerID: "groq", model: "llama-3.3-70b-versatile")

        store.selection = nil

        let reloaded = CloudProviderSelectionStore(userDefaults: defaults)
        #expect(reloaded.selection == nil)
    }
}
