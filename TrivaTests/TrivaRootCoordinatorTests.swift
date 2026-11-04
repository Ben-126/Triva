//
//  TrivaRootCoordinatorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/10/2026.
//

import Foundation
import Testing
@testable import Triva

/// Faux trousseau : aucune entrée/sortie, aucun accès au vrai Keychain.
private struct CoordinatorTestKeyStore: APIKeyStoring {
    var storedKey: String?

    func apiKey(account: String) throws -> String? { storedKey }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

/// Stores entièrement jetables, comme `SearchSessionEngineBindingTests` :
/// domaine `UserDefaults` unique, base SwiftData en mémoire, faux trousseau,
/// liste SearXNG explicite (jamais celle du bundle, qui peut différer
/// volontairement d'une machine à l'autre).
@MainActor
private func makeStores(instances: [URL] = [URL(string: "https://searx.example")!]) throws -> TrivaSharedStores {
    let userDefaults = try #require(UserDefaults(suiteName: "test.rootCoordinator.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: instances, userDefaults: userDefaults),
        keyStore: CoordinatorTestKeyStore(storedKey: "sk-test")
    )
}

/// Conversation enregistrée comme le ferait le chat : question à l'envoi,
/// réponse à la fin.
@MainActor
private func saveConversation(
    in stores: TrivaSharedStores,
    question: String = "Quelle heure est-il à Tokyo ?",
    answer: String = "Il est 9 h à Tokyo."
) throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: question)
    try stores.chatHistory.appendUserMessage(to: conversation, text: question)
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: answer)
    return conversation.id
}

/// Les actions entre espaces d'une fenêtre (mission I4b). Chaque test passe
/// par le VRAI `ChatViewModel` créé par la session, branché sur les stores
/// partagés : c'est ce branchement qu'ils verrouillent.
@MainActor
@Suite("TrivaRootCoordinator — actions entre espaces")
struct TrivaRootCoordinatorTests {
    @Test("Lancement : Recherche, conversation vierge, même avec un historique")
    func launchStartsOnABlankConversation() throws {
        let stores = try makeStores()
        _ = try saveConversation(in: stores)

        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        #expect(coordinator.selection == .search)
        #expect(coordinator.session.draft.text.isEmpty)
        // Init sans effet de bord : le chat n'existe qu'à la première apparition.
        #expect(coordinator.session.chatViewModel == nil)

        coordinator.session.ensureChatViewModel()
        let chat = try #require(coordinator.session.chatViewModel)
        #expect(chat.messages.isEmpty)
        #expect(chat.currentConversationID == nil)
    }

    /// Échoue sans `historyStore` dans `ensureChatViewModel` (le chargement
    /// rend `false`, fil vide) et sans la création du chat dans
    /// `openConversation` (Bibliothèque ouverte avant toute Recherche).
    @Test("Bibliothèque : ouvrir une conversation avant toute Recherche la charge et y bascule")
    func openingAConversationBeforeTheSearchEverAppeared() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores, question: "Question", answer: "Réponse")
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.selection = .library

        coordinator.openConversation(id: id)

        let chat = try #require(coordinator.session.chatViewModel)
        #expect(chat.currentConversationID == id)
        #expect(chat.messages.map(\.text) == ["Question", "Réponse"])
        #expect(coordinator.selection == .search)
    }

    @Test("Conversation introuvable : bascule quand même, erreur affichée, fil conservé")
    func openingAMissingConversationKeepsTheThread() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)
        coordinator.selection = .favorites

        coordinator.openConversation(id: UUID())

        let chat = try #require(coordinator.session.chatViewModel)
        #expect(coordinator.selection == .search)
        #expect(chat.persistenceErrorDescription == ChatViewModel.missingConversationMessage)
        #expect(chat.currentConversationID == id)
        #expect(chat.messages.count == 2)
    }

    /// Échoue sans `favoritesStore` dans `ensureChatViewModel` : l'étoile
    /// serait refusée (`canToggleFavorite` faux) et rien ne serait marqué.
    @Test("Favoris : une réponse rouverte se marque dans le store PARTAGÉ")
    func favoritesAreWiredToTheSharedStore() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)
        let chat = try #require(coordinator.session.chatViewModel)
        let answer = try #require(chat.messages.last)
        let storedID = try #require(answer.storedMessageID)
        #expect(chat.canToggleFavorite(answer))

        chat.toggleFavorite(messageID: answer.id)

        #expect(try stores.favorites.isFavorite(messageID: storedID))
    }

    @Test("Suppression dans une AUTRE fenêtre : le fil qui l'affichait repart à neuf")
    func deletionInAnotherWindowResetsTheThread() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)

        // L'autre fenêtre écrit directement dans le store partagé.
        let stored = try #require(try stores.chatHistory.conversation(with: id))
        try stores.chatHistory.delete(stored)
        coordinator.historyDidChange()

        let chat = try #require(coordinator.session.chatViewModel)
        #expect(chat.messages.isEmpty)
        #expect(chat.currentConversationID == nil)
    }

    @Test("« Tout effacer » vide aussi le fil, sans passer par onConversationDeleted")
    func clearingTheHistoryResetsTheThread() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)

        try stores.chatHistory.deleteAll()
        coordinator.historyDidChange()

        #expect(coordinator.session.chatViewModel?.messages.isEmpty == true)
    }

    @Test("Historique modifié ailleurs, conversation toujours là : le fil ne bouge pas")
    func unrelatedHistoryChangesKeepTheThread() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)

        let other = try saveConversation(in: stores, question: "Autre", answer: "Autre réponse")
        let stored = try #require(try stores.chatHistory.conversation(with: other))
        try stores.chatHistory.delete(stored)
        coordinator.historyDidChange()

        let chat = try #require(coordinator.session.chatViewModel)
        #expect(chat.currentConversationID == id)
        #expect(chat.messages.count == 2)
    }

    @Test("Bibliothèque de cette fenêtre : seule la suppression de la conversation du fil la vide")
    func libraryDeletionCallbackOnlyResetsTheOpenConversation() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores)
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores)
        coordinator.openConversation(id: id)

        coordinator.conversationWasDeleted(id: UUID())
        #expect(coordinator.session.chatViewModel?.messages.count == 2)

        coordinator.conversationWasDeleted(id: id)
        #expect(coordinator.session.chatViewModel?.messages.isEmpty == true)
    }

    @Test("Découvrir > « Chercher dans Triva » : titre nettoyé dans la barre, bascule sur Recherche")
    func discoverSearchPrefillsTheDraft() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        coordinator.selection = .discover

        coordinator.search(Self.makeArticle(title: "  Le télescope\n  James Webb\tdétecte "))

        #expect(coordinator.session.draft.text == "Le télescope James Webb détecte")
        #expect(coordinator.selection == .search)
        // Rien n'est envoyé : la question reste à préciser par l'utilisateur.
        #expect(coordinator.session.chatViewModel?.messages.isEmpty ?? true)
    }

    @Test("Titre vide : le brouillon en cours n'est pas effacé")
    func blankTitleKeepsTheDraft() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        coordinator.session.draft.text = "ma question"

        coordinator.search(Self.makeArticle(title: " \n "))

        #expect(coordinator.session.draft.text == "ma question")
        #expect(coordinator.selection == .search)
    }

    /// Liste d'instances VIDE : chargé à travers la session, Découvrir échoue
    /// aussitôt (`noInstancesConfigured`), sans réseau. Le repli
    /// `DiscoverViewModel.standalone`, lui, lirait la liste du bundle et
    /// partirait sur le réseau.
    @Test("Découvrir cherche sur la liste d'instances effective de l'app")
    func discoverLoadsThroughTheAppInstanceList() async throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores(instances: []))

        await coordinator.discover.loadIfNeeded()

        #expect(coordinator.discover.phase == .failed)
    }

    @Test("Réglages : « Configurer une clé API » mène aux Réglages de la fenêtre")
    func showSettingsSelectsSettings() throws {
        let coordinator = TrivaRootCoordinator(engine: .cloudBYOK, stores: try makeStores())

        coordinator.showSettings()

        #expect(coordinator.selection == .settings)
    }

    @Test("Chat : « Ajouter une clé de recherche » mène à l'écran des clés, dans les Réglages de la fenêtre")
    func showSearchKeysOpensTheSearchKeysScreen() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        #expect(coordinator.settingsPath.isEmpty)

        coordinator.showSearchKeys()

        #expect(coordinator.selection == .settings)
        #expect(coordinator.settingsPath == [.searchKeys])
    }

    @Test("Un écran resté poussé (autre destination visitée entre-temps) est remplacé par celui des clés")
    func showSearchKeysReplacesAPushedScreen() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        coordinator.settingsPath = [.mlxStorage]

        coordinator.showSearchKeys()

        #expect(coordinator.settingsPath == [.searchKeys])
    }

    /// « Gérer les clés API » et « Fournisseur et modèle » sont sur la racine des
    /// Réglages : sans cette remise à zéro, « Configurer une clé API » les
    /// cacherait derrière l'écran des clés de recherche resté poussé.
    @Test("« Configurer une clé API » revient à la racine des Réglages, même après l'écran des clés")
    func showSettingsReturnsToTheSettingsRoot() throws {
        let coordinator = TrivaRootCoordinator(engine: .cloudBYOK, stores: try makeStores())
        coordinator.showSearchKeys()
        coordinator.selection = .search

        coordinator.showSettings()

        #expect(coordinator.selection == .settings)
        #expect(coordinator.settingsPath.isEmpty)
    }

    /// Ce que la coquille pose dans l'environnement, appelé comme le fait `ChatView`.
    @Test("L'action de l'environnement ouvre l'écran des clés, et deux rendus de la coquille donnent la même valeur")
    func theEnvironmentActionOpensTheSearchKeysScreen() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        let makeAction = { OpenSearchKeySettingsAction(owner: coordinator) { coordinator.showSearchKeys() } }

        let action = makeAction()
        action()

        #expect(coordinator.selection == .settings)
        #expect(coordinator.settingsPath == [.searchKeys])
        // Sinon, chaque rendu de la coquille réévaluerait `ChatView`.
        #expect(action == makeAction())
        let otherWindow = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeStores())
        #expect(action != OpenSearchKeySettingsAction(owner: otherWindow, handler: {}))
    }

    private static func makeArticle(title: String) -> DiscoverArticle {
        DiscoverArticle(
            topic: .tech,
            result: SearXNGSearchResult(
                title: title, url: "https://exemple.fr/article", content: nil,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        )
    }
}

/// Démarrage à froid et budget de la session (mission I4b).
@MainActor
@Suite("SearchSession — démarrage à froid et budget")
struct SearchSessionSetupTests {
    @Test("Cloud sans fournisseur : action demandée, levée dès qu'une sélection existe")
    func cloudRequiresAProviderUntilOneIsSelected() throws {
        let stores = try makeStores()
        let session = SearchSession(engine: .cloudBYOK, stores: stores)
        #expect(session.setupRequirement == .cloudProvider)

        // Choisi dans les Réglages (de cette fenêtre ou d'une autre).
        stores.cloudSelection.selection = CloudProviderSelection(
            providerID: CloudBYOKProviderKind.claude.rawValue,
            model: "claude-sonnet-5"
        )
        #expect(session.setupRequirement == nil)
    }

    @Test("MLX sans modèle validé : action demandée")
    func mlxRequiresAModel() throws {
        let session = SearchSession(engine: .mlxLocal, stores: try makeStores())
        #expect(session.setupRequirement == .mlxModel)
    }

    @Test("Messages : français, actionnables, jamais d'identifiant brut ni de texte du framework")
    func setupMessagesAreReadable() {
        let errors: [AppleIntelligenceError] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unavailableForOtherReason,
            .generationFailed(description: "FoundationModels internal error 42"),
        ]
        for error in errors {
            let message = SearchSetupRequirement.appleIntelligenceUnavailable(error).message
            #expect(message?.contains("Apple Intelligence") == true)
            #expect(message?.contains(String(describing: error)) == false)
            #expect(message?.contains("FoundationModels internal error") == false)
        }
        #expect(SearchSetupRequirement.cloudProvider.message?.contains("clé API") == true)
        // Le bouton « Choisir un modèle MLX » de l'en-tête se suffit.
        #expect(SearchSetupRequirement.mlxModel.message == nil)
    }

    /// Une conversation rouverte reste lisible même quand le moteur n'est pas
    /// prêt ; un chat vide voué à l'échec, jamais.
    @Test("Chat affiché si le moteur est prêt, ou si le fil a déjà des messages")
    func chatVisibilityRule() {
        #expect(EngineStatusView.showsChat(requirement: nil, hasMessages: false))
        #expect(EngineStatusView.showsChat(requirement: nil, hasMessages: true))
        #expect(!EngineStatusView.showsChat(requirement: .cloudProvider, hasMessages: false))
        #expect(EngineStatusView.showsChat(requirement: .cloudProvider, hasMessages: true))
        #expect(!EngineStatusView.showsChat(requirement: .mlxModel, hasMessages: false))
    }

    /// Avant I4b, aucun budget n'était transmis : tous les moteurs, cloud
    /// compris, tournaient avec celui d'Apple Intelligence (bug 6).
    @Test("Budget : celui du moteur de la session ; MLX sans modèle préparé, le compact")
    func pipelineConfigurationFollowsTheEngine() throws {
        let stores = try makeStores()
        #expect(SearchSession(engine: .cloudBYOK, stores: stores).pipelineConfigurationForSending() == .cloud)
        #expect(SearchSession(engine: .appleIntelligence, stores: stores).pipelineConfigurationForSending() == .appleIntelligence)
        #expect(SearchSession(engine: .mlxLocal, stores: stores).pipelineConfigurationForSending() == .mlxCompact)
    }
}

/// Bug signalé par l'étape B : `BYOKProvidersView` construisait chaque
/// `APIKeysViewModel` avec son PROPRE `CloudProviderSelectionStore()`.
/// Supprimer la clé du fournisseur actif laissait alors la sélection de l'app
/// orpheline. Les fabriques sont celles qu'utilise la vue.
@MainActor
@Suite("BYOKProvidersView — sélection cloud partagée")
struct BYOKSharedSelectionTests {
    private func makeSelectionStore() throws -> CloudProviderSelectionStore {
        let userDefaults = try #require(UserDefaults(suiteName: "test.byokShared.\(UUID().uuidString)"))
        return CloudProviderSelectionStore(userDefaults: userDefaults)
    }

    @Test("Supprimer la clé du fournisseur actif (catalogue) efface la sélection PARTAGÉE")
    func deletingTheActiveCatalogKeyClearsTheSharedSelection() throws {
        let shared = try makeSelectionStore()
        let preset = try #require(CloudProviderCatalog.presets.first)
        shared.selection = CloudProviderSelection(providerID: preset.id, model: "modele-test")
        let viewModel = BYOKProvidersView.makeViewModel(
            for: preset,
            selectionStore: shared,
            keyStore: CoordinatorTestKeyStore(storedKey: "sk-test")
        )

        viewModel.deleteStoredKey()

        #expect(shared.selection == nil)
    }

    @Test("Supprimer la clé Claude active efface la sélection PARTAGÉE")
    func deletingTheActiveClaudeKeyClearsTheSharedSelection() throws {
        let shared = try makeSelectionStore()
        shared.selection = CloudProviderSelection(
            providerID: CloudBYOKProviderKind.claude.rawValue,
            model: "claude-sonnet-5"
        )
        let viewModel = BYOKProvidersView.makeClaudeViewModel(
            selectionStore: shared,
            keyStore: CoordinatorTestKeyStore(storedKey: "sk-test")
        )

        viewModel.deleteStoredKey()

        #expect(shared.selection == nil)
    }

    @Test("Supprimer la clé d'un AUTRE fournisseur garde la sélection active")
    func deletingAnotherKeyKeepsTheSelection() throws {
        let shared = try makeSelectionStore()
        let preset = try #require(CloudProviderCatalog.presets.first)
        let active = CloudProviderSelection(providerID: preset.id, model: "modele-test")
        shared.selection = active
        let claude = BYOKProvidersView.makeClaudeViewModel(
            selectionStore: shared,
            keyStore: CoordinatorTestKeyStore(storedKey: "sk-test")
        )

        claude.deleteStoredKey()

        #expect(shared.selection == active)
    }
}
