//
//  BYOKProvidersViewDeletionTests.swift
//  TrivaTests
//
//  Suppression d'un fournisseur « Personnalisé » depuis la liste des clés API (mission E2x1).
//

import Testing
import Foundation
@testable import Triva

/// Faux trousseau : jamais le vrai de la machine qui exécute les tests.
private final class DeletionKeyStore: APIKeyStoring, @unchecked Sendable {
    var keys: [String: String] = [:]
    private(set) var deletedAccounts: [String] = []

    func apiKey(account: String) throws -> String? { keys[account] }
    func save(apiKey: String, account: String) throws { keys[account] = apiKey }
    func deleteAPIKey(account: String) throws {
        deletedAccounts.append(account)
        keys[account] = nil
    }
}

@MainActor
@Suite("BYOKProvidersView — suppression d'un fournisseur personnalisé")
struct BYOKProvidersViewDeletionTests {
    private struct Fixture {
        let store: CustomProviderStore
        let selection: CloudProviderSelectionStore
        let keys: DeletionKeyStore
        let preset: CloudProviderPreset
    }

    private func makeFixture() -> Fixture {
        let selection = CloudProviderSelectionStore(
            userDefaults: UserDefaults(suiteName: "test.byokDeletion.selection.\(UUID().uuidString)")!
        )
        let keys = DeletionKeyStore()
        let store = CustomProviderStore(
            userDefaults: UserDefaults(suiteName: "test.byokDeletion.providers.\(UUID().uuidString)")!,
            selectionStore: selection,
            keyStore: keys
        )
        let preset = store.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )
        return Fixture(store: store, selection: selection, keys: keys, preset: preset)
    }

    private func viewModel(for preset: CloudProviderPreset, _ fixture: Fixture) -> APIKeysViewModel {
        BYOKProvidersView.makeViewModel(for: preset, selectionStore: fixture.selection, keyStore: fixture.keys)
    }

    @Test("Retire le fournisseur de la liste, oublie son view model et efface sa clé du trousseau")
    func removesPresetViewModelAndKey() throws {
        let fixture = makeFixture()
        try fixture.keys.save(apiKey: "secret", account: fixture.preset.id)
        var viewModels = [fixture.preset.id: viewModel(for: fixture.preset, fixture)]
        #expect(viewModels[fixture.preset.id]?.hasStoredKey == true)

        BYOKProvidersView.removeCustomProvider(fixture.preset, from: fixture.store, viewModels: &viewModels)

        #expect(fixture.store.customPresets.isEmpty)
        #expect(viewModels[fixture.preset.id] == nil)
        #expect(fixture.keys.deletedAccounts == [fixture.preset.id])
        #expect(try fixture.keys.apiKey(account: fixture.preset.id) == nil)
    }

    @Test("Ne touche ni aux autres fournisseurs, ni à leurs clés, ni à leur view model")
    func keepsOtherProviders() throws {
        let fixture = makeFixture()
        let other = fixture.store.add(
            displayName: "Autre",
            baseURL: URL(string: "https://autre.example.com/v1")!,
            model: "m"
        )
        try fixture.keys.save(apiKey: "autre-secret", account: other.id)
        var viewModels = [
            fixture.preset.id: viewModel(for: fixture.preset, fixture),
            other.id: viewModel(for: other, fixture)
        ]

        BYOKProvidersView.removeCustomProvider(fixture.preset, from: fixture.store, viewModels: &viewModels)

        #expect(fixture.store.customPresets == [other])
        #expect(viewModels.keys.contains(other.id))
        #expect(try fixture.keys.apiKey(account: other.id) == "autre-secret")
    }

    @Test("Supprimer le fournisseur actif ramène le moteur cloud à « choisir un fournisseur »")
    func removingActiveProviderLeavesACoherentState() throws {
        let fixture = makeFixture()
        try fixture.keys.save(apiKey: "secret", account: fixture.preset.id)
        fixture.selection.selection = CloudProviderSelection(providerID: fixture.preset.id, model: "mon-modele")
        let mlx = MLXModelSelectionStore(
            userDefaults: UserDefaults(suiteName: "test.byokDeletion.mlx.\(UUID().uuidString)")!
        )
        func resolve() throws -> any AIGenerating {
            try ActiveAIProviderResolver.resolve(
                engine: .cloudBYOK,
                mlxSelection: mlx,
                mlxCatalog: [],
                cloudSelection: fixture.selection,
                customCloudPresets: fixture.store.customPresets,
                keyStore: fixture.keys
            )
        }
        _ = try resolve() // avant : le fournisseur personnalisé est bien résolu
        var viewModels = [fixture.preset.id: viewModel(for: fixture.preset, fixture)]

        BYOKProvidersView.removeCustomProvider(fixture.preset, from: fixture.store, viewModels: &viewModels)

        #expect(fixture.selection.selection == nil)
        #expect(throws: ActiveAIProviderResolverError.noCloudSelectionStored) { try resolve() }
    }

    @Test("Supprimer un fournisseur qui n'est pas actif laisse la sélection en place")
    func removingInactiveProviderKeepsSelection() {
        let fixture = makeFixture()
        let claude = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        fixture.selection.selection = claude
        var viewModels: [String: APIKeysViewModel] = [:]

        BYOKProvidersView.removeCustomProvider(fixture.preset, from: fixture.store, viewModels: &viewModels)

        #expect(fixture.selection.selection == claude)
    }

    @Test("Le message prévient quand le fournisseur est celui utilisé en ce moment")
    func messageWarnsAboutActiveProvider() {
        let fixture = makeFixture()
        let activeSelection = CloudProviderSelection(providerID: fixture.preset.id, model: "m")
        let otherSelection = CloudProviderSelection(providerID: "claude", model: "m")

        #expect(BYOKProvidersView.isActive(fixture.preset, selection: activeSelection))
        #expect(!BYOKProvidersView.isActive(fixture.preset, selection: otherSelection))
        #expect(!BYOKProvidersView.isActive(fixture.preset, selection: nil))

        let plain = BYOKProvidersView.deletionMessage(isActive: false)
        let active = BYOKProvidersView.deletionMessage(isActive: true)
        #expect(plain.contains("clé API"))
        #expect(active.hasPrefix(plain))
        #expect(active.count > plain.count)
        #expect(BYOKProvidersView.deletionTitle(for: fixture.preset) == "Supprimer Mon LLM\u{00A0}?")
    }
}
