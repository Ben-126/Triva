//
//  AIProviderSelectorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import Testing
@testable import Triva

private struct MockDeviceCapabilities: DeviceCapabilityProviding {
    let isAppleIntelligenceAvailable: Bool
    let physicalMemoryBytes: UInt64
}

/// Trousseau factice : aucun test ne doit toucher au vrai Keychain.
private struct NoOpAPIKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
@Suite("AIProviderSelector")
struct AIProviderSelectorTests {
    @Test("Recommande Apple Intelligence quand l'appareil le supporte, peu importe la RAM")
    func recommendsAppleIntelligenceWhenAvailable() {
        let capabilities = MockDeviceCapabilities(isAppleIntelligenceAvailable: true, physicalMemoryBytes: 2_000_000_000)

        let recommendation = AIProviderSelector.recommend(for: capabilities)

        #expect(recommendation == AIEngineRecommendation(option: .appleIntelligence))
    }

    @Test("Recommande MLX local quand Apple Intelligence est indisponible")
    func recommendsMLXWhenAppleIntelligenceUnavailable() {
        let capabilities = MockDeviceCapabilities(isAppleIntelligenceAvailable: false, physicalMemoryBytes: 4_000_000_000)

        let recommendation = AIProviderSelector.recommend(for: capabilities)

        #expect(recommendation == AIEngineRecommendation(option: .mlxLocal))
    }
}

@MainActor
@Suite("AIEngineSettingsStore")
struct AIEngineSettingsStoreTests {
    @Test("Persiste et recharge le moteur choisi")
    func persistsSelectedOption() {
        let suiteName = "AIEngineSettingsStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = AIEngineSettingsStore(userDefaults: userDefaults)
        #expect(store.selectedOption == nil)

        store.selectedOption = .cloudBYOK

        let reloaded = AIEngineSettingsStore(userDefaults: userDefaults)
        #expect(reloaded.selectedOption == .cloudBYOK)
    }

    /// Fige la cause racine du bug 10, et donc la raison d'être d'une instance
    /// UNIQUE créée par `TrivaApp` : le store ne lit `UserDefaults` qu'à sa
    /// construction. Deux instances (l'ancien `@State` par fenêtre) divergent
    /// dès que l'une écrit. Si un jour le store se met à suivre les écritures
    /// des autres instances, ce test le signalera — et l'instance unique
    /// restera de toute façon la bonne architecture.
    @Test("Deux instances sur le même domaine divergent en mémoire : d'où une instance unique par app")
    func twoInstancesDivergeInMemory() {
        let suiteName = "AIEngineSettingsStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let windowA = AIEngineSettingsStore(userDefaults: userDefaults)
        let windowB = AIEngineSettingsStore(userDefaults: userDefaults)
        windowA.selectedOption = .appleIntelligence
        windowB.selectedOption = .cloudBYOK

        #expect(windowA.selectedOption == .appleIntelligence)
        #expect(AIEngineSettingsStore(userDefaults: userDefaults).selectedOption == .cloudBYOK)
    }
}

/// Le regroupement des stores uniques de l'app (`TrivaSharedStores`, créé une
/// fois par `TrivaApp`). Tout est jetable : domaine `UserDefaults` unique, base
/// SwiftData en mémoire, faux trousseau, liste SearXNG explicite.
@MainActor
@Suite("TrivaSharedStores")
struct TrivaSharedStoresTests {
    private func makeStores() throws -> TrivaSharedStores {
        let userDefaults = UserDefaults(suiteName: "TrivaSharedStoresTests.\(UUID().uuidString)")!
        let container = try TrivaModelContainer.makeInMemory()
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: container,
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(
                defaultInstances: [URL(string: "https://searx.example")!],
                userDefaults: userDefaults
            ),
            keyStore: NoOpAPIKeyStore()
        )
    }

    /// Chaque fenêtre reçoit une COPIE du struct : elle doit porter les mêmes
    /// instances, sans quoi on retrouverait un store par fenêtre (bug 10).
    @Test("Deux fenêtres qui reçoivent les stores voient le même moteur")
    func windowsShareTheEngineStore() throws {
        let stores = try makeStores()
        let windowA = stores
        let windowB = stores

        windowB.engineSettings.selectedOption = .cloudBYOK

        #expect(windowA.engineSettings === windowB.engineSettings)
        #expect(windowA.engineSettings.selectedOption == .cloudBYOK)
    }

    /// Couplage qui vivait dans `TrivaApp.init` : supprimer le fournisseur
    /// personnalisé ACTIF doit effacer la sélection vue par toute l'app, pas
    /// celle d'un `CloudProviderSelectionStore` privé au `CustomProviderStore`.
    @Test("Supprimer le fournisseur personnalisé actif efface la sélection cloud partagée")
    func customProvidersShareTheCloudSelection() throws {
        let stores = try makeStores()
        let preset = stores.customProviders.add(
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            model: "mon-modele"
        )
        stores.cloudSelection.selection = CloudProviderSelection(providerID: preset.id, model: "mon-modele")

        stores.customProviders.remove(id: preset.id)

        #expect(stores.cloudSelection.selection == nil)
    }

    /// Un seul conteneur : deux conteneurs sur le même fichier seraient deux
    /// stores concurrents qui s'ignorent (voir `TrivaModelContainer`).
    @Test("Historique et favoris travaillent sur le même conteneur SwiftData")
    func historyAndFavoritesShareOneContainer() throws {
        let stores = try makeStores()

        #expect(stores.chatHistory.container === stores.favorites.container)
    }
}
