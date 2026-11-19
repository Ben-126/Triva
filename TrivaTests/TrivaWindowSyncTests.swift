//
//  TrivaWindowSyncTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M2) : la valeur de la fenêtre suit le fil affiché, et inversement.
//

import Foundation
import Testing
@testable import Triva

private struct WindowTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makeWindowStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.windowSync.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: WindowTestKeyStore()
    )
}

@MainActor
private func saveWindowConversation(in stores: TrivaSharedStores, question: String = "Quelle heure est-il à Tokyo ?") throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: question)
    try stores.chatHistory.appendUserMessage(to: conversation, text: question)
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Il est 9 h.")
    return conversation.id
}

@MainActor
private func makeWindowCoordinator(
    stores: TrivaSharedStores,
    registry: WindowConversationRegistry = WindowConversationRegistry()
) -> TrivaRootCoordinator {
    TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
}

@MainActor
@Suite("Fenêtres — registre et restauration")
struct WindowRegistryTests {
    @Test("Une conversation affichée par une autre fenêtre est repérée, pas par la sienne")
    func displayedElsewhere() {
        let registry = WindowConversationRegistry()
        let windowA = UUID(), windowB = UUID(), conversation = UUID()
        registry.setDisplayed(conversation, in: windowA)
        #expect(registry.isDisplayed(conversation, excluding: windowB))
        #expect(!registry.isDisplayed(conversation, excluding: windowA))
    }

    @Test("Fenêtre fermée ou recherche neuve : la conversation n'est plus réservée")
    func removalAndClearing() {
        let registry = WindowConversationRegistry()
        let windowA = UUID(), windowB = UUID(), conversation = UUID()
        registry.setDisplayed(conversation, in: windowA)
        registry.setDisplayed(nil, in: windowA)
        #expect(!registry.isDisplayed(conversation, excluding: windowB))
        registry.setDisplayed(conversation, in: windowA)
        registry.remove(window: windowA)
        #expect(!registry.isDisplayed(conversation, excluding: windowB))
    }

    @Test("La cible de restauration ne se consomme qu'une fois")
    func restorationIsOneShot() {
        let target = TrivaWindowTarget.conversation(UUID())
        let restoration = WindowRestoration(initial: target)
        #expect(restoration.take() == target)
        #expect(restoration.take() == nil)
    }

    @Test("Identifiant de scène stable : il est écrit dans la restauration des fenêtres")
    func sceneIdentifier() {
        #expect(TrivaWindowTarget.sceneID == "recherche")
    }
}

@MainActor
@Suite("Fenêtres — coordinateur")
struct TrivaWindowCoordinatorTests {
    @Test("Lancement : recherche neuve, titre « Nouvelle recherche »")
    func launchIsANewSearch() throws {
        let coordinator = makeWindowCoordinator(stores: try makeWindowStores())
        #expect(coordinator.windowTarget.conversationID == nil)
        #expect(coordinator.searchTitle == "Nouvelle recherche")
    }

    @Test("Ouvrir une conversation met la cible à .conversation et le titre à celui de la conversation")
    func openingSetsTheTarget() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores, question: "Météo à Lyon demain")
        let coordinator = makeWindowCoordinator(stores: stores)

        coordinator.openConversation(id: id)

        #expect(coordinator.windowTarget == .conversation(id))
        #expect(coordinator.searchTitle.contains("Météo"))
    }

    @Test("Nouvelle conversation remet une recherche neuve, avec un identifiant NEUF")
    func startingNewConversationResetsTheTarget() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let coordinator = makeWindowCoordinator(stores: stores)
        coordinator.openConversation(id: id)
        let opened = coordinator.windowTarget

        coordinator.session.chatViewModel?.startNewConversation()
        coordinator.syncWindowTarget()

        guard case .newSearch = coordinator.windowTarget else {
            Issue.record("Attendu : .newSearch, obtenu \(coordinator.windowTarget)")
            return
        }
        #expect(coordinator.windowTarget != opened)
        #expect(coordinator.searchTitle == "Nouvelle recherche")
    }

    @Test("Une recherche déjà neuve garde son identifiant à chaque synchronisation")
    func freshSearchKeepsItsIdentity() throws {
        let coordinator = makeWindowCoordinator(stores: try makeWindowStores())
        let before = coordinator.windowTarget
        coordinator.syncWindowTarget()
        coordinator.syncWindowTarget(refreshTitle: true)
        #expect(coordinator.windowTarget == before)
    }

    @Test("Restauration : une conversation qui existe est rouverte")
    func restoringAnExistingConversation() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let coordinator = makeWindowCoordinator(stores: stores)

        coordinator.restoreWindowTarget(.conversation(id))

        #expect(coordinator.windowTarget == .conversation(id))
        #expect(coordinator.session.chatViewModel?.currentConversationID == id)
        #expect(coordinator.session.chatViewModel?.messages.isEmpty == false)
    }

    @Test("Restauration : une conversation supprimée entre-temps donne une recherche neuve, sans erreur")
    func restoringADeletedConversation() throws {
        let stores = try makeWindowStores()
        let coordinator = makeWindowCoordinator(stores: stores)

        coordinator.restoreWindowTarget(.conversation(UUID()))

        #expect(coordinator.windowTarget.conversationID == nil)
        #expect(coordinator.session.chatViewModel?.persistenceErrorDescription == nil)
    }

    @Test("Restauration : une recherche neuve garde son identifiant")
    func restoringANewSearchKeepsItsIdentifier() throws {
        let coordinator = makeWindowCoordinator(stores: try makeWindowStores())
        let target = TrivaWindowTarget.newSearch(UUID())
        coordinator.restoreWindowTarget(target)
        #expect(coordinator.windowTarget == target)
    }

    @Test("Le registre suit la fenêtre : conversation ouverte puis fil vidé")
    func registryFollowsTheWindow() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let registry = WindowConversationRegistry()
        let coordinator = makeWindowCoordinator(stores: stores, registry: registry)
        let other = UUID()

        coordinator.openConversation(id: id)
        #expect(registry.isDisplayed(id, excluding: other))

        coordinator.session.chatViewModel?.startNewConversation()
        coordinator.syncWindowTarget()
        #expect(!registry.isDisplayed(id, excluding: other))
    }

    @Test("Conversation supprimée ailleurs : la fenêtre redevient une recherche neuve")
    func historyDeletionResetsTheTarget() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let coordinator = makeWindowCoordinator(stores: stores)
        coordinator.openConversation(id: id)

        try stores.chatHistory.deleteAll()
        coordinator.historyDidChange()

        #expect(coordinator.windowTarget.conversationID == nil)
    }

    @Test("Bibliothèque : conversation déjà affichée AILLEURS -> on ramène l'autre fenêtre, rien n'est chargé ici")
    func historyOpenRoutesToTheOtherWindow() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let registry = WindowConversationRegistry()
        let windowA = makeWindowCoordinator(stores: stores, registry: registry)
        let windowB = makeWindowCoordinator(stores: stores, registry: registry)
        windowA.openConversation(id: id)

        var routed: UUID?
        windowB.openConversationFromHistory(id: id, canUseOtherWindows: true) { routed = $0 }

        #expect(routed == id)
        #expect(windowB.session.chatViewModel?.currentConversationID == nil)
        #expect(windowB.windowTarget.conversationID == nil)
    }

    @Test("Bibliothèque : conversation libre, ou appareil à une seule fenêtre -> ouverture sur place")
    func historyOpenStaysInPlace() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let registry = WindowConversationRegistry()
        let windowA = makeWindowCoordinator(stores: stores, registry: registry)
        let windowB = makeWindowCoordinator(stores: stores, registry: registry)

        var routed = false
        windowA.openConversationFromHistory(id: id, canUseOtherWindows: true) { _ in routed = true }
        #expect(!routed)
        #expect(windowA.windowTarget == .conversation(id))

        // iPhone : une seule fenêtre, même si le registre dit « ailleurs ».
        windowB.openConversationFromHistory(id: id, canUseOtherWindows: false) { _ in routed = true }
        #expect(!routed)
        #expect(windowB.session.chatViewModel?.currentConversationID == id)
    }

    @Test("Ouvrir sa propre conversation depuis la Bibliothèque ne passe pas par une autre fenêtre")
    func ownConversationIsNotElsewhere() throws {
        let stores = try makeWindowStores()
        let id = try saveWindowConversation(in: stores)
        let registry = WindowConversationRegistry()
        let coordinator = makeWindowCoordinator(stores: stores, registry: registry)
        coordinator.openConversation(id: id)

        var routed = false
        coordinator.openConversationFromHistory(id: id, canUseOtherWindows: true) { _ in routed = true }
        #expect(!routed)
    }
}
