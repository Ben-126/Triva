//
//  RootSystemRouteTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : ce que fait la fenêtre d'une route système. Aucune route n'envoie une question.
//

import Foundation
import Testing
@testable import Triva

private struct RouteKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func routeStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.systemRoute.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: RouteKeyStore()
    )
}

/// Fenêtre sur un moteur cloud AVEC fournisseur et accord : si une route envoyait quelque chose, elle partirait.
@MainActor
private func readyWindow(stores: TrivaSharedStores? = nil) throws -> TrivaRootCoordinator {
    let stores = try stores ?? routeStores()
    stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")
    stores.cloudConsent.grant(providerID: "openai")
    return TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())
}

@MainActor
@Suite("Fenêtre — routes système")
struct RootSystemRouteTests {
    // MARK: Nouvelle question

    @Test("Nouvelle question, fil vide : Recherche affichée, clavier demandé (+1), rien envoyé")
    func newQuestionOnEmptyThread() throws {
        let window = try readyWindow()
        window.selection = .library
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        let before = chat.userNewConversationCount

        let outcome = window.apply(.newQuestion(.keyboard))

        #expect(outcome == .newQuestion)
        #expect(window.selection == .search)
        #expect(chat.userNewConversationCount == before + 1)
        #expect(chat.messages.isEmpty)
        #expect(!chat.isGenerating)
    }

    @Test("Nouvelle question avec une conversation ouverte : le fil repart à neuf (comme ⇧⌘O), clavier demandé")
    func newQuestionClearsOpenConversation() throws {
        let stores = try routeStores()
        let conversation = try stores.chatHistory.createConversation(title: "Ancienne")
        let window = try readyWindow(stores: stores)
        window.openConversation(id: conversation.id)
        #expect(window.windowTarget == .conversation(conversation.id))
        let chat = try #require(window.session.chatViewModel)
        let before = chat.userNewConversationCount

        window.apply(.newQuestion(.keyboard))

        #expect(chat.currentConversationID == nil)
        #expect(chat.userNewConversationCount == before + 1)
        #expect(window.windowTarget.conversationID == nil)
    }

    @Test("Nouvelle question sur un fil vide : le fichier joint pas encore envoyé est retiré (décision du 25/11), le clavier est demandé")
    func newQuestionOnEmptyThreadRemovesUnsentAttachedFile() async throws {
        let window = try readyWindow()
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString).txt")
        try "Contenu du fichier joint.".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await chat.attachmentController.store.attach(fileAt: file)
        #expect(chat.attachmentController.attachments.count == 1)

        window.apply(.newQuestion(.keyboard))

        #expect(chat.attachmentController.attachments.isEmpty)
        #expect(chat.consumePendingFocusRequest() == true)
    }

    @Test("Saisie vocale : ouvre le clavier tant que le drapeau est éteint")
    func voiceOpensKeyboardWhileFlagOff() throws {
        #expect(TrivaFeatureFlags.voiceInput == false)
        let window = try readyWindow()
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        let before = chat.userNewConversationCount

        #expect(window.apply(.newQuestion(.voice)) == .newQuestion)
        #expect(chat.userNewConversationCount == before + 1)
    }

    // MARK: Brouillon

    @Test("Brouillon : placé assaini dans la barre de saisie, Recherche affichée, JAMAIS envoyé")
    func draftIsPlacedNotSent() throws {
        let window = try readyWindow()
        window.selection = .favorites

        let outcome = window.apply(.draft("  Pourquoi le ciel\u{200B} est bleu ?\n"))

        #expect(outcome == .draftPlaced)
        #expect(window.session.draft.text == "Pourquoi le ciel est bleu ?")
        #expect(window.selection == .search)
        let chat = window.session.chatViewModel
        #expect(chat?.messages.isEmpty ?? true)
        #expect(!(chat?.isGenerating ?? false))
        #expect(chat?.pendingConsent == nil)
    }

    @Test("Brouillon vide ou illisible : ignoré, la barre de saisie en cours n'est pas touchée")
    func emptyDraftIsIgnored() throws {
        let window = try readyWindow()
        window.session.draft.text = "Ce que je tapais"
        window.selection = .library

        #expect(window.apply(.draft(" \u{200B}\n ")) == .ignored)

        #expect(window.session.draft.text == "Ce que je tapais")
        #expect(window.selection == .library)
    }

    // MARK: Conversation

    @Test("Conversation connue : ouverte dans la Recherche, la cible de la fenêtre la suit")
    func knownConversationOpens() throws {
        let stores = try routeStores()
        let conversation = try stores.chatHistory.createConversation(title: "Le ciel")
        let window = try readyWindow(stores: stores)
        window.selection = .settings

        let outcome = window.apply(.conversation(conversation.id))

        #expect(outcome == .conversationOpened)
        #expect(window.selection == .search)
        #expect(window.session.chatViewModel?.currentConversationID == conversation.id)
        #expect(window.windowTarget == .conversation(conversation.id))
    }

    @Test("Identifiant inconnu : « Cette conversation n'existe plus. », le fil en cours est gardé")
    func unknownConversationSaysSo() throws {
        let window = try readyWindow()
        window.selection = .library

        let outcome = window.apply(.conversation(UUID()))

        #expect(outcome == .conversationMissing)
        #expect(window.selection == .search)
        #expect(window.session.chatViewModel?.persistenceErrorDescription == "Cette conversation n'existe plus.")
        #expect(window.session.chatViewModel?.currentConversationID == nil)
    }

    @Test("iPad : une conversation tenue par une AUTRE fenêtre passe devant, sans être chargée ici")
    func conversationHeldElsewhereIsBroughtForward() throws {
        let stores = try routeStores()
        let conversation = try stores.chatHistory.createConversation(title: "Ailleurs")
        let registry = WindowConversationRegistry()
        let other = UUID()
        registry.setDisplayed(conversation.id, in: other)
        var focused = false
        registry.setFocusAction({ focused = true; return true }, in: other)
        stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")
        let window = TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: registry)
        var openedInWindow: UUID?

        let outcome = window.apply(.conversation(conversation.id), canUseOtherWindows: true) { openedInWindow = $0 }

        #expect(outcome == .conversationOpened)
        #expect(focused)
        #expect(openedInWindow == nil)
        #expect(window.session.chatViewModel?.currentConversationID == nil)
    }
}
