//
//  ActiveAIProviderResolverTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 06/09/2026.
//

import Testing
import Foundation
import ClaudeForFoundationModels
@testable import Triva

/// Faux magasin de clés API, même pattern que `CloudProviderSelectionResolverTests`.
private struct MockAPIKeyStore: APIKeyStoring {
    var storedKey: String?

    func apiKey(account: String) throws -> String? { storedKey }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@Suite("ActiveAIProviderResolver")
struct ActiveAIProviderResolverTests {
    private static func makeMLXEntry(id: String) -> MLXModelCatalogEntry {
        MLXModelCatalogEntry(
            id: id,
            displayName: id,
            huggingFaceRepo: "mlx-community/\(id)",
            registryKey: nil,
            license: "Apache 2.0",
            downloadSizeBytes: 1,
            recommendedGPUWorkingSetBytes: 1,
            capabilityScore: 1,
            supportsThinkingMode: true,
            isMixtureOfExperts: false,
            isAdvancedOnly: false,
            summary: "",
            strengths: [],
            tradeoffs: []
        )
    }

    private func uniqueDefaults(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: "test.activeAIProviderResolver.\(label).\(UUID().uuidString)")!
    }

    private func makeStores() -> (AIEngineSettingsStore, MLXModelSelectionStore, CloudProviderSelectionStore) {
        (
            AIEngineSettingsStore(userDefaults: uniqueDefaults("engine")),
            MLXModelSelectionStore(userDefaults: uniqueDefaults("mlx")),
            CloudProviderSelectionStore(userDefaults: uniqueDefaults("cloud"))
        )
    }

    @Test("Aucun moteur sélectionné -> erreur dédiée")
    func noEngineSelected() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = nil

        #expect(throws: ActiveAIProviderResolverError.noEngineSelected) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("Apple Intelligence sélectionné et disponible -> retourne un AppleIntelligenceProvider")
    func appleIntelligenceAvailable() throws {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .appleIntelligence

        // NB : sur cette machine de test, `SystemLanguageModel.default` peut être
        // disponible ou non selon l'environnement CI/local. On teste donc le
        // comportement de façon conditionnelle sur la disponibilité réelle,
        // comme le fait déjà `AppleIntelligenceProviderTests` (si un tel fichier existe) —
        // ici on vérifie simplement la cohérence du résultat avec `availabilityError`.
        let probe = AppleIntelligenceProvider()

        let resolved = try? ActiveAIProviderResolver.resolve(
            engineSettings: engineStore,
            mlxSelection: mlxStore,
            mlxCatalog: [],
            cloudSelection: cloudStore,
            customCloudPresets: [],
            keyStore: MockAPIKeyStore()
        )

        if probe.availabilityError == nil {
            #expect(resolved is AppleIntelligenceProvider)
        } else {
            #expect(resolved == nil)
        }
    }

    @Test("Apple Intelligence sélectionné mais indisponible -> erreur portant l'AppleIntelligenceError")
    func appleIntelligenceUnavailable() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .appleIntelligence

        let probe = AppleIntelligenceProvider()
        guard let expectedError = probe.availabilityError else {
            // Sur cette machine, Apple Intelligence est disponible : ce cas ne
            // peut pas être exercé sans simuler l'indisponibilité (pas de seam
            // pour ça côté `AppleIntelligenceProvider`) — on saute simplement,
            // mais en le signalant explicitement (sévérité `.warning`, donc
            // sans faire échouer la suite) pour qu'un lecteur du rapport de
            // tests distingue "branche vérifiée" de "branche sautée".
            Issue.record(
                "Apple Intelligence est disponible sur cette machine : la branche appleIntelligenceUnavailable n'est pas exercée par ce test.",
                severity: .warning
            )
            return
        }

        #expect(throws: ActiveAIProviderResolverError.appleIntelligenceUnavailable(expectedError)) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("MLX sélectionné avec un modelID stocké présent dans le catalogue -> MLXProvider résolu correspond à l'entrée attendue")
    func mlxResolvedWithStoredModelID() async throws {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .mlxLocal
        let entry = Self.makeMLXEntry(id: "qwen3-1_7b-4bit")
        let catalog = [Self.makeMLXEntry(id: "qwen3-0_6b-4bit"), entry]
        mlxStore.selectedModelID = entry.id

        let resolved = try ActiveAIProviderResolver.resolve(
            engineSettings: engineStore,
            mlxSelection: mlxStore,
            mlxCatalog: catalog,
            cloudSelection: cloudStore,
            customCloudPresets: [],
            keyStore: MockAPIKeyStore()
        )

        let provider = try #require(resolved as? MLXProvider)
        let resolvedEntry = await provider.entry
        #expect(resolvedEntry == entry)
    }

    @Test("MLX sélectionné sans modelID stocké -> erreur dédiée")
    func mlxWithoutStoredModelID() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .mlxLocal
        mlxStore.selectedModelID = nil

        #expect(throws: ActiveAIProviderResolverError.noMLXModelSelected) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [Self.makeMLXEntry(id: "qwen3-0_6b-4bit")],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("MLX sélectionné avec un modelID stocké absent du catalogue -> erreur dédiée")
    func mlxWithModelIDMissingFromCatalog() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .mlxLocal
        mlxStore.selectedModelID = "modele-disparu"

        #expect(throws: ActiveAIProviderResolverError.mlxModelNotInCatalog(modelID: "modele-disparu")) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [Self.makeMLXEntry(id: "qwen3-0_6b-4bit")],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("Cloud sélectionné avec une sélection résolvable (preset connu + modèle Claude connu) -> provider résolu")
    func cloudResolvedWithClaudeSelection() throws {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        cloudStore.selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: "claude-sonnet-5"
        )

        let resolved = try ActiveAIProviderResolver.resolve(
            engineSettings: engineStore,
            mlxSelection: mlxStore,
            mlxCatalog: [],
            cloudSelection: cloudStore,
            customCloudPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try #require(resolved as? CloudBYOKProvider)
        #expect(provider.model.id == "claude-sonnet-5")
    }

    @Test("Cloud sélectionné avec une sélection résolvable (preset personnalisé) -> provider résolu")
    func cloudResolvedWithCustomPreset() throws {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele-defaut"
        )
        cloudStore.selection = CloudProviderSelection(providerID: custom.id, model: "mon-modele-choisi")

        let resolved = try ActiveAIProviderResolver.resolve(
            engineSettings: engineStore,
            mlxSelection: mlxStore,
            mlxCatalog: [],
            cloudSelection: cloudStore,
            customCloudPresets: [custom],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try #require(resolved as? OpenAICompatibleProvider)
        #expect(provider.account == "custom:abc")
        #expect(provider.model == "mon-modele-choisi")
    }

    @Test("Cloud sélectionné sans sélection stockée -> erreur dédiée")
    func cloudWithoutStoredSelection() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        cloudStore.selection = nil

        #expect(throws: ActiveAIProviderResolverError.noCloudSelectionStored) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("Cloud sélectionné avec un providerID inconnu -> erreur dédiée")
    func cloudWithUnknownProviderID() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        let selection = CloudProviderSelection(providerID: "inconnu", model: "peu importe")
        cloudStore.selection = selection

        #expect(throws: ActiveAIProviderResolverError.cloudSelectionUnresolvable(selection)) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }

    @Test("Cloud sélectionné avec un modèle Claude inconnu -> erreur dédiée")
    func cloudWithUnknownClaudeModel() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        let selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: "claude-modele-inconnu"
        )
        cloudStore.selection = selection

        #expect(throws: ActiveAIProviderResolverError.cloudSelectionUnresolvable(selection)) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: engineStore,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore(storedKey: "sk-test")
            )
        }
    }
}
