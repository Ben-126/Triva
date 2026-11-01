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

/// Faux client HTTP pour la liste des modèles : réponse fixe, appels comptés.
private final class StubModelListRequester: HTTPDataRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let statusCode: Int
    private let body: String

    init(statusCode: Int = 200, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    var callCount: Int { lock.withLock { _callCount } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _callCount += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@MainActor
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

    // MARK: - Menu déroulant des modèles

    private func makeViewModel(
        keys: [String: String],
        selection: CloudProviderSelection?,
        requester: StubModelListRequester
    ) -> CloudProviderModelPickerViewModel {
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = selection
        return CloudProviderModelPickerViewModel(
            keyStore: MockAPIKeyStore(storedKeys: keys),
            customPresets: [],
            selectionStore: selectionStore,
            modelListService: CloudModelListService(requester: requester, cache: CloudModelListCache())
        )
    }

    @Test("Charge la liste et la propose dans le menu")
    func loadsModelsIntoMenu() async {
        let requester = StubModelListRequester(body: #"{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"llama-3.1-8b-instant"}]}"#)
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq"],
            selection: CloudProviderSelection(providerID: "groq", model: "llama-3.3-70b-versatile"),
            requester: requester
        )

        await viewModel.loadModels()

        #expect(viewModel.modelMenuOptions.map(\.id) == ["llama-3.1-8b-instant", "llama-3.3-70b-versatile"])
        #expect(!viewModel.showsManualModelEntry)
    }

    @Test("Le modèle courant absent de la liste reste proposé, en tête")
    func currentModelMissingFromListStaysVisible() async {
        let requester = StubModelListRequester(body: #"{"data":[{"id":"llama-3.1-8b-instant"}]}"#)
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq"],
            selection: CloudProviderSelection(providerID: "groq", model: "mon-modele-retire"),
            requester: requester
        )

        await viewModel.loadModels()

        #expect(viewModel.modelMenuOptions.map(\.id) == ["mon-modele-retire", "llama-3.1-8b-instant"])
    }

    @Test("Choisir un modèle du menu met à jour la sélection persistée")
    func choosingMenuModelUpdatesSelection() async {
        let requester = StubModelListRequester(body: #"{"data":[{"id":"a"},{"id":"b"}]}"#)
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq"],
            selection: CloudProviderSelection(providerID: "groq", model: "a"),
            requester: requester
        )
        await viewModel.loadModels()

        viewModel.updateModel(to: "b")

        #expect(viewModel.selectedModel == "b")
        #expect(viewModel.modelMenuOptions.map(\.id) == ["a", "b"])
    }

    @Test("Changer de fournisseur réinitialise l'état de la liste")
    func switchingProviderResetsListState() async {
        let requester = StubModelListRequester(body: #"{"data":[{"id":"a"}]}"#)
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq", "mistral": "sk-mistral"],
            selection: CloudProviderSelection(providerID: "groq", model: "a"),
            requester: requester
        )
        await viewModel.loadModels()

        viewModel.selectProvider(id: "mistral")

        #expect(viewModel.modelListState == .idle)
        #expect(!viewModel.showsManualModelEntry)
    }

    @Test("Sans clé lisible : aucun appel réseau, saisie manuelle en repli")
    func noKeyMakesNoRequest() async {
        // Clé présente à l'init (fournisseur configuré) puis illisible : on
        // simule avec un magasin dont la clé a disparu entre-temps.
        let requester = StubModelListRequester(body: #"{"data":[]}"#)
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "groq", model: "a")
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: DisappearingKeyStore(account: "groq"),
            customPresets: [],
            selectionStore: selectionStore,
            modelListService: CloudModelListService(requester: requester, cache: CloudModelListCache())
        )

        await viewModel.loadModels()

        #expect(viewModel.modelListState == .noKey)
        #expect(viewModel.showsManualModelEntry)
        #expect(requester.callCount == 0)
    }

    @Test("Erreur temporaire → .failed, pas de saisie manuelle, Réessayer refait l'appel")
    func temporaryFailureOffersRetryOnly() async {
        let requester = StubModelListRequester(statusCode: 503, body: "{}")
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq-secret"],
            selection: CloudProviderSelection(providerID: "groq", model: "a"),
            requester: requester
        )

        await viewModel.loadModels()
        #expect(viewModel.modelListState == .failed(message: CloudModelListError.serverUnavailable.message))
        #expect(!viewModel.showsManualModelEntry)
        #expect(viewModel.modelMenuOptions.map(\.id) == ["a"])

        await viewModel.loadModels(forceRefresh: true)
        #expect(requester.callCount == 2)
    }

    @Test("Endpoint de liste absent (fournisseur personnalisé) → saisie manuelle en repli")
    func missingListEndpointFallsBackToManualEntry() async {
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele"
        )
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "custom:abc", model: "mon-modele")
        let viewModel = CloudProviderModelPickerViewModel(
            keyStore: MockAPIKeyStore(storedKeys: ["custom:abc": "sk-custom"]),
            customPresets: [custom],
            selectionStore: selectionStore,
            modelListService: CloudModelListService(
                requester: StubModelListRequester(statusCode: 404, body: "Not Found"),
                cache: CloudModelListCache()
            )
        )

        await viewModel.loadModels()

        #expect(viewModel.modelListState == .unavailable(message: CloudModelListError.listUnavailable.message))
        #expect(viewModel.showsManualModelEntry)
    }

    @Test("Format de liste inconnu → saisie manuelle en repli")
    func unknownListFormatFallsBackToManualEntry() async {
        let viewModel = makeViewModel(
            keys: ["groq": "sk-groq"],
            selection: CloudProviderSelection(providerID: "groq", model: "a"),
            requester: StubModelListRequester(body: #"{"models":"inattendu"}"#)
        )

        await viewModel.loadModels()

        #expect(viewModel.showsManualModelEntry)
    }

    @Test("Claude : tous les modèles de l'API, ids datés ramenés à l'alias connu")
    func claudeListsAllFetchedModels() async {
        let requester = StubModelListRequester(body: """
        {"data":[
          {"id":"claude-opus-5","display_name":"Claude Opus 5"},
          {"id":"claude-futur-9","display_name":"Claude Futur 9"},
          {"id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"}
        ]}
        """)
        let viewModel = makeViewModel(
            keys: ["claude": "sk-claude"],
            selection: CloudProviderSelection(providerID: "claude", model: "claude-opus-5"),
            requester: requester
        )

        await viewModel.loadModels()

        #expect(viewModel.modelMenuOptions == [
            CloudModelOption(id: "claude-opus-5", displayName: "Claude Opus 5"),
            CloudModelOption(id: "claude-futur-9", displayName: "Claude Futur 9"),
            CloudModelOption(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        ])
        #expect(!viewModel.showsManualModelEntry)
    }

    @Test("Claude avant chargement : tous les modèles connus restent proposés")
    func claudeFallsBackToKnownModels() {
        let viewModel = makeViewModel(
            keys: ["claude": "sk-claude"],
            selection: CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5"),
            requester: StubModelListRequester(body: "{}")
        )

        #expect(viewModel.modelMenuOptions.map(\.id) == CloudProviderSelectionResolver.knownClaudeModels.map(\.id))
    }
}

/// Clé lisible au premier accès (init du view model), absente ensuite.
private final class DisappearingKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let account: String
    private var reads = 0

    init(account: String) { self.account = account }

    func apiKey(account: String) throws -> String? {
        lock.withLock {
            guard account == self.account else { return nil }
            reads += 1
            return reads == 1 ? "sk-temporaire" : nil
        }
    }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}
