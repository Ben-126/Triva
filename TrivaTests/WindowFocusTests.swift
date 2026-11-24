//
//  WindowFocusTests.swift
//  TrivaTests
//
//  Mission F3 : une conversation déjà tenue par une autre fenêtre ramène CETTE fenêtre devant, au lieu
//  d'ouvrir une fenêtre vide (rapport W2-G1, point 4).
//

import Foundation
import Testing
@testable import Triva

private struct FocusKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func focusStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.windowFocus.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: FocusKeyStore()
    )
}

@MainActor
private func focusConversation(in stores: TrivaSharedStores) throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: "Question")
    try stores.chatHistory.appendUserMessage(to: conversation, text: "Question")
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Réponse.")
    return conversation.id
}

/// Compte combien de fois une fenêtre a été ramenée devant.
@MainActor
private final class FocusCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@MainActor
@Suite("Registre — ramener la fenêtre d'une conversation devant")
struct WindowRegistryFocusTests {
    @Test("La fenêtre qui AFFICHE la conversation est ramenée devant")
    func displayedHolderIsFocused() {
        let registry = WindowConversationRegistry()
        let holder = UUID(), other = UUID(), conversation = UUID()
        let counter = FocusCounter()
        registry.setDisplayed(conversation, in: holder)
        registry.setFocusAction({ counter.bump(); return true }, in: holder)

        #expect(registry.focusHolder(of: conversation, excluding: other))
        #expect(counter.count == 1)
    }

    @Test("La fenêtre dont une réponse écrit encore dans la conversation est ramenée devant aussi")
    func backgroundHolderIsFocused() {
        let registry = WindowConversationRegistry()
        let holder = UUID(), other = UUID(), conversation = UUID()
        let counter = FocusCounter()
        registry.setBackgroundConversation({ conversation }, in: holder)
        registry.setFocusAction({ counter.bump(); return true }, in: holder)

        #expect(registry.focusHolder(of: conversation, excluding: other))
        #expect(counter.count == 1)
    }

    @Test("Jamais la fenêtre exclue, ni une fenêtre qui ne tient pas la conversation")
    func excludedAndUnrelatedWindows() {
        let registry = WindowConversationRegistry()
        let window = UUID(), conversation = UUID()
        let counter = FocusCounter()
        registry.setDisplayed(conversation, in: window)
        registry.setFocusAction({ counter.bump(); return true }, in: window)

        #expect(!registry.focusHolder(of: conversation, excluding: window))
        #expect(!registry.focusHolder(of: UUID(), excluding: nil))
        #expect(counter.count == 0)
    }

    @Test("Une action qui n'a pas pu ramener la fenêtre (fenêtre système pas connue) compte pour un échec : l'appelant se replie")
    func failingActionFallsThrough() {
        let registry = WindowConversationRegistry()
        let holder = UUID(), conversation = UUID()
        registry.setDisplayed(conversation, in: holder)
        registry.setFocusAction({ false }, in: holder)
        #expect(!registry.focusHolder(of: conversation, excluding: nil))
    }

    @Test("Sans action de mise au premier plan (ou fenêtre fermée), rien n'est ramené : l'appelant se replie")
    func noActionNoFocus() {
        let registry = WindowConversationRegistry()
        let holder = UUID(), conversation = UUID()
        registry.setDisplayed(conversation, in: holder)
        #expect(!registry.focusHolder(of: conversation, excluding: nil))

        let counter = FocusCounter()
        registry.setFocusAction({ counter.bump(); return true }, in: holder)
        registry.remove(window: holder)
        #expect(!registry.focusHolder(of: conversation, excluding: nil))
        #expect(counter.count == 0)
    }
}

@MainActor
@Suite("Fenêtres — conversation déjà tenue ailleurs")
struct HeldConversationFocusTests {
    @Test("Bibliothèque : la fenêtre qui tient la conversation passe devant, aucune fenêtre n'est ouverte")
    func libraryFocusesTheHolder() throws {
        let stores = try focusStores()
        let id = try focusConversation(in: stores)
        let registry = WindowConversationRegistry()
        let holder = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
        holder.openConversation(id: id)
        let counter = FocusCounter()
        registry.setFocusAction({ counter.bump(); return true }, in: holder.windowID)
        let window = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)

        var openedWindow = false
        window.openConversationFromHistory(id: id, canUseOtherWindows: true) { _ in openedWindow = true }

        #expect(counter.count == 1)
        #expect(!openedWindow)
        #expect(window.session.chatViewModel?.currentConversationID == nil)
    }

    @Test("Sans moyen de ramener la fenêtre devant, on retombe sur openWindow (qui ramène la fenêtre de la valeur)")
    func fallsBackToOpenWindow() throws {
        let stores = try focusStores()
        let id = try focusConversation(in: stores)
        let registry = WindowConversationRegistry()
        let holder = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
        holder.openConversation(id: id)
        let window = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)

        var opened: UUID?
        window.openConversationFromHistory(id: id, canUseOtherWindows: true) { opened = $0 }

        #expect(opened == id)
    }

    @Test("Fenêtre neuve créée sur une conversation tenue ailleurs : la fenêtre qui la tient passe devant")
    func refusedRestorationFocusesTheHolder() throws {
        let stores = try focusStores()
        let id = try focusConversation(in: stores)
        let registry = WindowConversationRegistry()
        let holder = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
        holder.openConversation(id: id)
        let counter = FocusCounter()
        registry.setFocusAction({ counter.bump(); return true }, in: holder.windowID)
        let window = TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)

        window.restoreWindowTarget(.conversation(id))

        #expect(counter.count == 1)
        #expect(window.windowTarget.conversationID == nil)
    }

    @Test("Barre des menus, « Récentes » : la fenêtre qui tient la conversation passe devant, rien n'est ouvert")
    func menuBarRecentFocusesTheHolder() throws {
        let registry = WindowConversationRegistry()
        let launcher = ExternalSearchLauncher()
        let holder = UUID(), id = UUID()
        let counter = FocusCounter()
        registry.setDisplayed(id, in: holder)
        registry.setFocusAction({ counter.bump(); return true }, in: holder)
        launcher.requestConversation(id)

        var opened: [TrivaWindowTarget] = []
        ExternalSearchWindowOpener(launcher: launcher, registry: registry, onlyWhenNoWindow: false) { opened.append($0) }
            .openPending()

        #expect(opened.isEmpty)
        #expect(counter.count == 1)
    }

    @Test("Barre des menus : une conversation que personne ne tient s'ouvre dans une fenêtre, une recherche neuve aussi")
    func menuBarOpensWhenNobodyHolds() {
        let registry = WindowConversationRegistry()
        let launcher = ExternalSearchLauncher()
        let id = UUID()
        launcher.requestConversation(id)
        launcher.requestNewSearch()

        var opened: [TrivaWindowTarget] = []
        ExternalSearchWindowOpener(launcher: launcher, registry: registry, onlyWhenNoWindow: false) { opened.append($0) }
            .openPending()

        #expect(opened.count == 2)
        #expect(opened.first == .conversation(id))
    }
}
