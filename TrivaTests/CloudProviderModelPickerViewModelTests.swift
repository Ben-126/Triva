//
//  CloudProviderModelPickerViewModelTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
import ClaudeForFoundationModels
@testable import Triva

/// Faux magasin de clés API, même pattern que les autres tests BYOK.
private struct MockAPIKeyStore: APIKeyStoring {
    var storedKeys: [String: String] = [:]

    func apiKey(account: String) throws -> String? { storedKeys[account] }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@Suite("CloudProviderModelPickerViewModel")
struct CloudProviderModelPickerViewModelTests {
    private func uniqueSelectionStore() -> CloudProviderSelectionStore {
        CloudProviderSelectionStore(userDefaults: UserDefaults(suiteName: "test.modelPickerVM.\(UUID().uuidString)")!)
    }

    @Test("Ne liste que les fournisseurs pour lesquels une clé est enregistrée")
    func onlyListsProvidersWithStoredKey() {
        let keyStore = MockAPIKeyStore(storedKeys: [
            "claude": "sk-claude",
            "groq": "sk-groq"
            // "openai" volontairement absent : pas configuré.
        ])
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: uniqueSelectionStore()
        )

        let ids = Set(viewModel.configuredProviders.map(\.id))
        #expect(ids == ["claude", "groq"])
    }

    @Test("Inclut les fournisseurs personnalisés configurés")
    func includesConfiguredCustomProviders() {
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele"
        )
        let keyStore = MockAPIKeyStore(storedKeys: ["custom:abc": "sk-custom"])
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [custom],
            selectionStore: uniqueSelectionStore()
        )

        #expect(viewModel.configuredProviders.map(\.id) == ["custom:abc"])
    }

    @Test("Ignore les clés vides comme non configurées")
    func treatsEmptyKeyAsNotConfigured() {
        let keyStore = MockAPIKeyStore(storedKeys: ["claude": ""])
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: uniqueSelectionStore()
        )

        #expect(viewModel.configuredProviders.isEmpty)
    }

    @Test("État vide géré sans crash quand aucun fournisseur n'est configuré")
    func emptyStateWhenNoProviderConfigured() {
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: MockAPIKeyStore(),
            customPresets: [],
            selectionStore: uniqueSelectionStore()
        )

        #expect(viewModel.configuredProviders.isEmpty)
        #expect(viewModel.selectedProviderID == nil)
    }

    @Test("Sélectionner Claude met à jour le store avec sonnet5 par défaut")
    func selectingClaudeUsesDefaultModel() {
        let keyStore = MockAPIKeyStore(storedKeys: ["claude": "sk-claude"])
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: selectionStore
        )

        viewModel.selectProvider(id: "claude")

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5"))
        #expect(viewModel.selectedProviderID == "claude")
    }

    @Test("Sélectionner un preset du catalogue utilise son defaultModel")
    func selectingCatalogPresetUsesItsDefaultModel() {
        let preset = CloudProviderCatalog.presets.first { $0.id == "groq" }!
        let keyStore = MockAPIKeyStore(storedKeys: ["groq": "sk-groq"])
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: selectionStore
        )

        viewModel.selectProvider(id: "groq")

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "groq", model: preset.defaultModel))
    }

    @Test("Sélectionner un preset personnalisé utilise son defaultModel")
    func selectingCustomPresetUsesItsDefaultModel() {
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele-defaut"
        )
        let keyStore = MockAPIKeyStore(storedKeys: ["custom:abc": "sk-custom"])
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [custom],
            selectionStore: selectionStore
        )

        viewModel.selectProvider(id: "custom:abc")

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "custom:abc", model: "mon-modele-defaut"))
    }

    @Test("Re-sélectionner le fournisseur déjà actif conserve son modèle actuel")
    func reselectingSameProviderKeepsCurrentModel() {
        let keyStore = MockAPIKeyStore(storedKeys: ["claude": "sk-claude"])
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "claude", model: "claude-opus-5")
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: selectionStore
        )

        viewModel.selectProvider(id: "claude")

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "claude", model: "claude-opus-5"))
    }

    @Test("Changer le modèle du fournisseur sélectionné met à jour la sélection persistée")
    func changingModelUpdatesPersistedSelection() {
        let keyStore = MockAPIKeyStore(storedKeys: ["groq": "sk-groq"])
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: selectionStore
        )
        viewModel.selectProvider(id: "groq")

        viewModel.updateModel(to: "llama-3.1-8b-instant")

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "groq", model: "llama-3.1-8b-instant"))
    }

    @Test("updateModel sans fournisseur sélectionné ne fait rien")
    func updateModelWithoutSelectionDoesNothing() {
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: MockAPIKeyStore(),
            customPresets: [],
            selectionStore: selectionStore
        )

        viewModel.updateModel(to: "peu importe")

        #expect(selectionStore.selection == nil)
    }

    @Test("selectedConfiguredProviderID reflète selectedProviderID quand il est configuré")
    func selectedConfiguredProviderIDMatchesWhenConfigured() {
        let keyStore = MockAPIKeyStore(storedKeys: ["claude": "sk-claude"])
        let selectionStore = uniqueSelectionStore()
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: keyStore,
            customPresets: [],
            selectionStore: selectionStore
        )

        viewModel.selectProvider(id: "claude")

        #expect(viewModel.selectedConfiguredProviderID == "claude")
    }

    @Test("selectedConfiguredProviderID est nil quand la sélection persistée est orpheline")
    func selectedConfiguredProviderIDNilWhenOrphaned() {
        // La sélection pointe vers "custom:abc", mais aucune clé n'est
        // enregistrée pour ce fournisseur : simule la suppression de la clé
        // (ou du preset personnalisé) depuis `BYOKProvidersView` après coup.
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "custom:abc", model: "mon-modele")
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: MockAPIKeyStore(storedKeys: [:]),
            customPresets: [],
            selectionStore: selectionStore
        )

        #expect(viewModel.selectedProviderID == "custom:abc")
        #expect(viewModel.selectedConfiguredProviderID == nil)
    }

    @Test("Nom lisible d'un modèle Claude dérivé de son id")
    func claudeModelDisplayNameDerivedFromID() {
        #expect(CloudProviderModelPickerViewModel.claudeModelDisplayName(for: .sonnet5) == "Sonnet 5")
        #expect(CloudProviderModelPickerViewModel.claudeModelDisplayName(for: .opus4_8) == "Opus 4.8")
        #expect(CloudProviderModelPickerViewModel.claudeModelDisplayName(for: .haiku4_5) == "Haiku 4.5")
    }
}
