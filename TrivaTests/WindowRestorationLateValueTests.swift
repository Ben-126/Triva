//
//  WindowRestorationLateValueTests.swift
//  TrivaTests
//
//  Mission F3 : la valeur de scène restaurée peut ARRIVER APRÈS le premier rendu de la fenêtre (constat du chef,
//  24/11 : fenêtres restaurées mais vides). Elle doit être prise en compte, sans jamais violer les règles de
//  fenêtres : une conversation n'est tenue que par une fenêtre, un changement de moteur repart d'une recherche
//  neuve, et une valeur que la fenêtre a elle-même publiée n'est jamais « restaurée ».
//

import Foundation
import Testing
@testable import Triva

private struct LateKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func lateStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.windowLate.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: LateKeyStore()
    )
}

@MainActor
private func lateConversation(in stores: TrivaSharedStores, question: String = "Quelle est la capitale du Chili ?") throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: question)
    try stores.chatHistory.appendUserMessage(to: conversation, text: question)
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Santiago.")
    return conversation.id
}

@MainActor
private func lateWindow(_ stores: TrivaSharedStores, _ registry: WindowConversationRegistry = WindowConversationRegistry()) -> TrivaRootCoordinator {
    TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: registry)
}

/// Rejoue ce que fait la coquille à sa première apparition (`TrivaRootShell.adoptWindowTarget`) : la cible
/// lue à la création de la vue est consommée, puis la cible de la fenêtre est notée comme déjà tenue.
@MainActor
private func firstAppearance(_ window: TrivaRootCoordinator, _ restoration: WindowRestoration) {
    if let initial = restoration.take() {
        window.restoreWindowTarget(initial)
    } else {
        window.syncWindowTarget()
    }
    restoration.noteHeld(window.windowTarget)
}

@MainActor
@Suite("Fenêtres — valeur restaurée arrivée après le premier rendu")
struct WindowLateRestorationTests {
    @Test("Première apparition sur la valeur par défaut, puis la conversation restaurée arrive : elle est rouverte")
    func lateConversationIsRestored() throws {
        let stores = try lateStores()
        let id = try lateConversation(in: stores)
        let window = lateWindow(stores)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)
        #expect(window.session.chatViewModel?.currentConversationID == nil)

        #expect(window.receiveLateWindowValue(.conversation(id), restoration: restoration))

        #expect(window.windowTarget == .conversation(id))
        #expect(window.session.chatViewModel?.currentConversationID == id)
        #expect(window.session.chatViewModel?.messages.isEmpty == false)
        #expect(window.selection == .search)
    }

    @Test("La valeur restaurée n'est prise qu'une fois")
    func lateValueIsOneShot() throws {
        let stores = try lateStores()
        let id = try lateConversation(in: stores)
        let window = lateWindow(stores)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)
        #expect(window.receiveLateWindowValue(.conversation(id), restoration: restoration))
        #expect(!window.receiveLateWindowValue(.conversation(id), restoration: restoration))
    }

    @Test("L'écho d'une valeur que la fenêtre a publiée elle-même n'est jamais « restauré »")
    func ownEchoIsIgnored() throws {
        let stores = try lateStores()
        let id = try lateConversation(in: stores)
        let window = lateWindow(stores)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)

        // L'utilisateur ouvre la conversation, puis en commence une neuve : la valeur .conversation(id) a été publiée.
        window.openConversation(id: id)
        restoration.noteHeld(window.windowTarget)
        window.session.chatViewModel?.startNewConversation()
        window.syncWindowTarget()
        restoration.noteHeld(window.windowTarget)
        let freshTarget = window.windowTarget

        // L'écho en retard de l'ancienne publication ne doit pas rouvrir la conversation.
        #expect(!window.receiveLateWindowValue(.conversation(id), restoration: restoration))
        #expect(window.windowTarget == freshTarget)
        #expect(window.session.chatViewModel?.currentConversationID == nil)
    }

    @Test("Fenêtre déjà occupée par une conversation : la valeur tardive est ignorée")
    func busyWindowKeepsItsConversation() throws {
        let stores = try lateStores()
        let shown = try lateConversation(in: stores, question: "Première")
        let other = try lateConversation(in: stores, question: "Seconde")
        let window = lateWindow(stores)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)
        window.openConversation(id: shown)

        #expect(!window.receiveLateWindowValue(.conversation(other), restoration: restoration))
        #expect(window.windowTarget == .conversation(shown))
    }

    @Test("Une recherche neuve arrivant après coup n'est pas une restauration")
    func lateFreshSearchIsIgnored() throws {
        let window = lateWindow(try lateStores())
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)
        let before = window.windowTarget
        #expect(!window.receiveLateWindowValue(.newSearch(UUID()), restoration: restoration))
        #expect(window.windowTarget == before)
    }

    @Test("Conversation déjà tenue par une autre fenêtre : celle-ci devient une recherche neuve, rien n'est chargé")
    func lateValueHeldElsewhere() throws {
        let stores = try lateStores()
        let id = try lateConversation(in: stores)
        let registry = WindowConversationRegistry()
        let holder = lateWindow(stores, registry)
        holder.openConversation(id: id)
        let window = lateWindow(stores, registry)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)

        window.receiveLateWindowValue(.conversation(id), restoration: restoration)

        #expect(window.windowTarget.conversationID == nil)
        #expect(window.session.chatViewModel?.currentConversationID == nil)
        #expect(holder.session.chatViewModel?.currentConversationID == id)
    }

    @Test("Changement de moteur : la coquille neuve repart d'une recherche neuve et ignore l'ancienne valeur")
    func engineChangeStartsFresh() throws {
        let stores = try lateStores()
        let id = try lateConversation(in: stores)
        let registry = WindowConversationRegistry()
        let restoration = WindowRestoration(initial: .conversation(id))
        let first = lateWindow(stores, registry)
        firstAppearance(first, restoration)
        #expect(first.windowTarget == .conversation(id))

        // `.id(selected)` : nouvelle coquille, même cible de restauration (déjà consommée).
        let rebuilt = TrivaRootCoordinator(engine: .mlxLocal, stores: stores, windowRegistry: registry)
        firstAppearance(rebuilt, restoration)
        #expect(rebuilt.windowTarget.conversationID == nil)

        // L'ancienne valeur, republiée en écho, ne rouvre rien : la valeur a été tenue par cette fenêtre.
        #expect(!rebuilt.receiveLateWindowValue(.conversation(id), restoration: restoration))
        #expect(rebuilt.session.chatViewModel?.currentConversationID == nil)
    }

    @Test("Conversation supprimée entre-temps : la valeur tardive donne une recherche neuve")
    func lateValueOfDeletedConversation() throws {
        let stores = try lateStores()
        let window = lateWindow(stores)
        let restoration = WindowRestoration(initial: .newSearch(UUID()))
        firstAppearance(window, restoration)

        window.receiveLateWindowValue(.conversation(UUID()), restoration: restoration)

        #expect(window.windowTarget.conversationID == nil)
        #expect(window.session.chatViewModel?.currentConversationID == nil)
    }
}
