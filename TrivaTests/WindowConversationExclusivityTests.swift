//
//  WindowConversationExclusivityTests.swift
//  TrivaTests
//
//  Chantier 2.2, mission G1 (revue R2, B8) : une conversation n'est tenue que par UNE fenêtre, même quand
//  une fenêtre est créée sur une conversation qu'une autre tient déjà (valeur de scène pas encore publiée,
//  panneau de la barre des menus, fenêtre recréée) ou qu'une réponse y écrit encore en arrière-plan.
//

import Foundation
import Testing
@testable import Triva

private struct ExclusivityKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makeStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.windowExclusivity.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: ExclusivityKeyStore()
    )
}

@MainActor
private func saveConversation(in stores: TrivaSharedStores, question: String) throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: question)
    try stores.chatHistory.appendUserMessage(to: conversation, text: question)
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Réponse.")
    return conversation.id
}

@MainActor
private func makeWindow(_ stores: TrivaSharedStores, _ registry: WindowConversationRegistry) -> TrivaRootCoordinator {
    TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
}

/// Fait croire à la fenêtre qu'une réponse continue d'écrire dans `conversation` en arrière-plan.
@MainActor
private func simulateBackgroundGeneration(in window: TrivaRootCoordinator, conversation: UUID) {
    window.session.ensureChatViewModel()
    window.session.chatViewModel?.backgroundExchange = BackgroundExchange(
        conversationID: conversation, exchangeID: UUID(), messages: [], sendTask: nil, generationTask: nil
    )
}

@MainActor
@Suite("Registre — conversations tenues")
struct WindowRegistryHeldTests {
    @Test("Une réponse en arrière-plan tient sa conversation, pour les AUTRES fenêtres seulement")
    func backgroundConversationIsHeld() {
        let registry = WindowConversationRegistry()
        let windowA = UUID(), windowB = UUID(), conversation = UUID()
        var background: UUID? = conversation
        registry.setBackgroundConversation({ background }, in: windowA)

        #expect(registry.isHeld(conversation, excluding: windowB))
        #expect(!registry.isHeld(conversation, excluding: windowA))
        #expect(!registry.isDisplayed(conversation, excluding: windowB))

        background = nil
        #expect(!registry.isHeld(conversation, excluding: windowB))
    }

    @Test("Une conversation affichée est tenue, et fermer la fenêtre libère tout")
    func displayedConversationIsHeldUntilRemoval() {
        let registry = WindowConversationRegistry()
        let windowA = UUID(), windowB = UUID()
        let shown = UUID(), background = UUID()
        registry.setDisplayed(shown, in: windowA)
        registry.setBackgroundConversation({ background }, in: windowA)
        #expect(registry.isHeld(shown, excluding: windowB))
        #expect(registry.isHeld(background, excluding: windowB))

        registry.remove(window: windowA)
        #expect(!registry.isHeld(shown, excluding: windowB))
        #expect(!registry.isHeld(background, excluding: windowB))
    }
}

@MainActor
@Suite("Fenêtres — une conversation, une fenêtre")
struct WindowConversationExclusivityTests {
    @Test("Fenêtre créée sur une conversation qu'une autre affiche : recherche neuve, rien n'est chargé")
    func duplicateRestoreBecomesAFreshSearch() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores, question: "Météo à Lyon demain")
        let registry = WindowConversationRegistry()
        let windowA = makeWindow(stores, registry)
        let windowB = makeWindow(stores, registry)
        windowA.openConversation(id: id)

        windowB.restoreWindowTarget(.conversation(id))

        guard case .newSearch = windowB.windowTarget else {
            Issue.record("Attendu : .newSearch, obtenu \(windowB.windowTarget)")
            return
        }
        #expect(windowB.session.chatViewModel?.currentConversationID == nil)
        #expect(windowB.searchTitle == TrivaRootCoordinator.newSearchTitle)
        // La conversation reste tenue par A seule.
        #expect(registry.isHeld(id, excluding: windowB.windowID))
        #expect(!registry.isHeld(id, excluding: windowA.windowID))
        #expect(windowA.windowTarget == .conversation(id))
    }

    @Test("La fenêtre qui la tenait est fermée : la restauration ouvre la conversation")
    func restoreSucceedsOnceTheOtherWindowIsGone() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores, question: "Météo à Lyon demain")
        let registry = WindowConversationRegistry()
        let windowA = makeWindow(stores, registry)
        let windowB = makeWindow(stores, registry)
        windowA.openConversation(id: id)
        registry.remove(window: windowA.windowID)

        windowB.restoreWindowTarget(.conversation(id))

        #expect(windowB.windowTarget == .conversation(id))
        #expect(windowB.session.chatViewModel?.currentConversationID == id)
    }

    @Test("Une réponse encore écrite en arrière-plan par une autre fenêtre tient la conversation")
    func backgroundGenerationBlocksADuplicateWindow() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores, question: "Météo à Lyon demain")
        let registry = WindowConversationRegistry()
        let windowA = makeWindow(stores, registry)
        let windowB = makeWindow(stores, registry)
        simulateBackgroundGeneration(in: windowA, conversation: id)

        // Bibliothèque de B : on route vers la fenêtre de A au lieu de charger ici.
        var routed: UUID?
        windowB.openConversationFromHistory(id: id, canUseOtherWindows: true) { routed = $0 }
        #expect(routed == id)
        #expect(windowB.session.chatViewModel?.currentConversationID == nil)

        // Fenêtre neuve sur cette conversation : recherche neuve.
        let windowC = makeWindow(stores, registry)
        windowC.restoreWindowTarget(.conversation(id))
        #expect(windowC.windowTarget.conversationID == nil)

        // La réponse se termine : la conversation est libre.
        windowA.session.chatViewModel?.backgroundExchange = nil
        windowB.restoreWindowTarget(.conversation(id))
        #expect(windowB.windowTarget == .conversation(id))
    }

    @Test("Appareil à une seule fenêtre : la restauration et l'ouverture sur place sont inchangées")
    func singleWindowIsUnchanged() throws {
        let stores = try makeStores()
        let id = try saveConversation(in: stores, question: "Météo à Lyon demain")
        let window = makeWindow(stores, WindowConversationRegistry())

        window.restoreWindowTarget(.conversation(id))
        #expect(window.windowTarget == .conversation(id))

        var routed = false
        window.openConversationFromHistory(id: id, canUseOtherWindows: true) { _ in routed = true }
        #expect(!routed)
    }

    @Test("Quelle que soit la suite d'ouvertures, jamais deux fenêtres sur la même conversation")
    func neverTwoWindowsOnTheSameConversation() throws {
        let stores = try makeStores()
        let first = try saveConversation(in: stores, question: "Première question")
        let second = try saveConversation(in: stores, question: "Deuxième question")
        let registry = WindowConversationRegistry()
        let windows = (0..<3).map { _ in makeWindow(stores, registry) }

        // Chaque fenêtre tente chaque conversation, par les deux chemins, dans plusieurs ordres.
        let attempts: [(window: Int, id: UUID, viaHistory: Bool)] = [
            (0, first, false), (1, first, false), (2, second, false),
            (1, second, true), (0, second, true), (2, first, true), (1, first, true),
        ]
        for attempt in attempts {
            let window = windows[attempt.window]
            if attempt.viaHistory {
                window.openConversationFromHistory(id: attempt.id, canUseOtherWindows: true) { _ in }
            } else {
                window.restoreWindowTarget(.conversation(attempt.id))
            }
            for id in [first, second] {
                let holders = windows.filter { $0.session.chatViewModel?.currentConversationID == id }
                #expect(holders.count <= 1, "conversation affichée par \(holders.count) fenêtres")
            }
        }
        #expect(windows[0].session.chatViewModel?.currentConversationID == first)
        #expect(windows[2].session.chatViewModel?.currentConversationID == second)
        #expect(windows[1].session.chatViewModel?.currentConversationID == nil)
    }
}
