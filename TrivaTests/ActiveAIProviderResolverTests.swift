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

@MainActor
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

    /// Depuis la décision de Ben du 2026-10-06 (liste des modèles via l'API du
    /// fournisseur), un id Claude INCONNU est accepté avec des capacités par
    /// défaut (`CloudProviderSelectionResolver.unknownClaudeModelCapabilities`) ;
    /// seul un modèle VIDE reste irrésolvable.
    @Test("Cloud sélectionné avec un modèle Claude vide -> erreur dédiée")
    func cloudWithEmptyClaudeModel() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        let selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: ""
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

    @Test("Cloud sélectionné avec un modèle Claude inconnu -> provider résolu sur cet id")
    func cloudResolvedWithUnknownClaudeModel() throws {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        cloudStore.selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: "claude-modele-futur"
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
        #expect(provider.model.id == "claude-modele-futur")
    }

    // MARK: - Bug 10 : quel moteur fait foi

    /// Garde de NON-RÉGRESSION (ce test passait déjà avant I4a : le code
    /// d'alors résolvait depuis le store de la fenêtre). Deux stores sur le
    /// MÊME domaine `UserDefaults` reproduisent deux fenêtres de l'ancien code :
    /// B écrit `.cloudBYOK` en dernier. Si le résolveur relisait
    /// `UserDefaults` (ou construisait un store neuf, comme la vue d'avant la
    /// coquille V1), il résoudrait le cloud — la sélection cloud est valide
    /// exprès. Il doit suivre l'instance fournie : MLX, sans modèle choisi.
    @Test("resolve(engineSettings:) suit l'instance fournie, jamais une relecture de UserDefaults")
    func resolutionUsesProvidedInstanceNotUserDefaults() {
        let sharedDomain = uniqueDefaults("shared-domain")
        let windowA = AIEngineSettingsStore(userDefaults: sharedDomain)
        let windowB = AIEngineSettingsStore(userDefaults: sharedDomain)
        let (_, mlxStore, cloudStore) = makeStores()
        cloudStore.selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: "claude-sonnet-5"
        )

        windowA.selectedOption = .mlxLocal
        windowB.selectedOption = .cloudBYOK

        // Précondition : le domaine persistant dit bien « cloud ».
        #expect(AIEngineSettingsStore(userDefaults: sharedDomain).selectedOption == .cloudBYOK)
        #expect(throws: ActiveAIProviderResolverError.noMLXModelSelected) {
            _ = try ActiveAIProviderResolver.resolve(
                engineSettings: windowA,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore(storedKey: "sk-test")
            )
        }
    }

    @Test("resolve(engine:) résout le moteur passé en valeur, quel que soit le store de moteur")
    func resolutionByValueIgnoresEngineStore() {
        let (engineStore, mlxStore, cloudStore) = makeStores()
        engineStore.selectedOption = .cloudBYOK
        cloudStore.selection = CloudProviderSelection(
            providerID: CloudProviderSelectionResolver.claudeProviderID,
            model: "claude-sonnet-5"
        )

        #expect(throws: ActiveAIProviderResolverError.noMLXModelSelected) {
            _ = try ActiveAIProviderResolver.resolve(
                engine: .mlxLocal,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore(storedKey: "sk-test")
            )
        }
    }

    @Test("resolve(engine: nil) -> aucun moteur sélectionné")
    func resolutionByValueWithoutEngine() {
        let (_, mlxStore, cloudStore) = makeStores()

        #expect(throws: ActiveAIProviderResolverError.noEngineSelected) {
            _ = try ActiveAIProviderResolver.resolve(
                engine: nil,
                mlxSelection: mlxStore,
                mlxCatalog: [],
                cloudSelection: cloudStore,
                customCloudPresets: [],
                keyStore: MockAPIKeyStore()
            )
        }
    }
}

/// Bug 10 au niveau de la session : le moteur utilisé pour l'envoi est
/// TOUJOURS celui que la fenêtre affiche dans son badge (`session.engine`),
/// même quand le store PARTAGÉ a basculé ailleurs (autre fenêtre, fenêtre
/// Réglages macOS) avant que la fenêtre ne soit reconstruite.
///
/// Les tests « ne bascule jamais » ÉCHOUENT si la session se remet à lire le
/// moteur dans le store au moment de l'envoi : la sélection cloud y est rendue
/// valide exprès, une relecture renverrait donc un provider cloud.
///
/// MLX n'est exercé que sans modèle choisi : la résolution échoue avant tout
/// `prepare()`, qui lèverait `simulatorUnsupported` sur le simulateur.
/// Stores entièrement jetables : domaine `UserDefaults` unique, base SwiftData
/// en mémoire, faux trousseau, liste SearXNG explicite (jamais celle du bundle,
/// qui peut différer volontairement d'une machine à l'autre).
@MainActor
@Suite("SearchSession — moteur affiché == moteur utilisé")
struct SearchSessionEngineBindingTests {
    private static var claudeSelection: CloudProviderSelection {
        CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-sonnet-5")
    }

    private func makeStores(instances: [URL] = [URL(string: "https://searx.example")!]) throws -> TrivaSharedStores {
        let userDefaults = UserDefaults(suiteName: "test.searchSession.\(UUID().uuidString)")!
        let container = try TrivaModelContainer.makeInMemory()
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: container,
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: instances, userDefaults: userDefaults),
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )
    }

    @Test("Session MLX : le store partagé passe au cloud, l'envoi reste sur MLX")
    func mlxSessionNeverSendsToCloud() async throws {
        let stores = try makeStores()
        stores.engineSettings.selectedOption = .mlxLocal
        let session = SearchSession(engine: .mlxLocal, stores: stores)

        // Une AUTRE fenêtre bascule l'app en cloud, sélection valide.
        stores.engineSettings.selectedOption = .cloudBYOK
        stores.cloudSelection.selection = Self.claudeSelection

        #expect(session.engine.privacyBadge.text.contains("Sur l'appareil"))
        await #expect(throws: ActiveAIProviderResolverError.noMLXModelSelected) {
            _ = try await session.resolveProviderForSending()
        }
    }

    @Test("Session Apple Intelligence : le store partagé passe au cloud, aucun provider cloud n'est résolu")
    func appleIntelligenceSessionNeverSendsToCloud() async throws {
        let stores = try makeStores()
        stores.engineSettings.selectedOption = .appleIntelligence
        let session = SearchSession(engine: .appleIntelligence, stores: stores)

        stores.engineSettings.selectedOption = .cloudBYOK
        stores.cloudSelection.selection = Self.claudeSelection

        #expect(session.engine.privacyBadge.text.contains("Sur l'appareil"))
        do {
            let provider = try await session.resolveProviderForSending()
            #expect(provider is AppleIntelligenceProvider)
            #expect(!(provider is CloudBYOKProvider))
            #expect(!(provider is OpenAICompatibleProvider))
        } catch let error as ActiveAIProviderResolverError {
            // Apple Intelligence indisponible sur cette machine : seule son
            // erreur est acceptable — jamais une résolution cloud.
            guard case .appleIntelligenceUnavailable = error else {
                Issue.record("Erreur inattendue pour une session Apple Intelligence : \(error)")
                return
            }
        }
    }

    @Test("Session cloud : le store partagé passe à Apple Intelligence, l'envoi reste celui que le badge annonce")
    func cloudSessionKeepsItsDisplayedEngine() async throws {
        let stores = try makeStores()
        stores.engineSettings.selectedOption = .cloudBYOK
        stores.cloudSelection.selection = Self.claudeSelection
        let session = SearchSession(engine: .cloudBYOK, stores: stores)

        stores.engineSettings.selectedOption = .appleIntelligence

        let provider = try await session.resolveProviderForSending()
        #expect(provider is CloudBYOKProvider)
        #expect(!session.engine.privacyBadge.text.contains("Sur l'appareil"))
    }

    /// Avant I4a, le provider cloud était mis en cache et invalidé par un
    /// `.onChange` de `EngineStatusView`, inactif quand cette vue est démontée
    /// (Réglages ouverts dans la sidebar ou dans la fenêtre Réglages macOS) :
    /// l'envoi suivant partait vers l'ANCIEN fournisseur. Ici, aucune vue
    /// n'existe : seul l'état des stores peut faire foi.
    @Test("Un changement de fournisseur cloud fait ailleurs est pris en compte au prochain envoi, sans vue montée")
    func cloudSelectionChangeIsPickedUpWithoutAnyView() async throws {
        let stores = try makeStores()
        stores.cloudSelection.selection = Self.claudeSelection
        let session = SearchSession(engine: .cloudBYOK, stores: stores)

        let first = try await session.resolveProviderForSending()
        #expect(first is CloudBYOKProvider)

        stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")

        let resolved = try await session.resolveProviderForSending()
        let second = try #require(resolved as? OpenAICompatibleProvider)
        #expect(second.account == "openai")
        #expect(second.model == "gpt-test")
    }

    @Test("Fournisseur cloud supprimé ailleurs : erreur dédiée au lieu d'un provider périmé")
    func clearedCloudSelectionIsNotServedFromCache() async throws {
        let stores = try makeStores()
        stores.cloudSelection.selection = Self.claudeSelection
        let session = SearchSession(engine: .cloudBYOK, stores: stores)
        _ = try await session.resolveProviderForSending()

        stores.cloudSelection.selection = nil

        await #expect(throws: ActiveAIProviderResolverError.noCloudSelectionStored) {
            _ = try await session.resolveProviderForSending()
        }
    }

    @Test("Le FailoverManager est réutilisé tant que la liste d'instances ne change pas, reconstruit sinon")
    func failoverManagerFollowsEffectiveInstances() throws {
        let instanceA = URL(string: "https://a.searx.example")!
        let instanceB = URL(string: "https://b.searx.example")!
        let stores = try makeStores(instances: [instanceA, instanceB])
        let session = SearchSession(engine: .appleIntelligence, stores: stores)

        let first = session.resolveFailoverManager()
        #expect(session.resolveFailoverManager() === first)

        try stores.searchInstances.remove(instanceB)

        let rebuilt = session.resolveFailoverManager()
        #expect(rebuilt !== first)
        #expect(session.resolveFailoverManager() === rebuilt)
    }
}
