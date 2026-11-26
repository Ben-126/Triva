//
//  NewQuestionEntryPathsTests.swift
//  TrivaTests
//
//  F3 (26/11), décision de Ben : une nouvelle question lancée du widget, de Siri, de Raccourcis, de la barre des menus ou du
//  bouton Action pendant qu'une réponse est en cours ne coupe JAMAIS cette réponse : elle finit et est enregistrée, la
//  nouvelle question s'ouvre à côté (même chemin que le bouton « Nouvelle conversation », W4-NC).
//
//  Un test par chemin d'entrée, à chaque couture qui existe déjà. Ce que ces tests ne couvrent PAS : une fenêtre COMPLÈTE
//  qui répond pendant que la route arrive (`TrivaRootCoordinator` fabrique son propre fournisseur, sans couture de test) ;
//  ce maillon, `ChatViewModel.startNewConversationFromSystem` pendant une réponse, est prouvé dans
//  `ChatViewModelSystemNewQuestionTests` (la réponse finit en arrière-plan et est enregistrée).
//

import Foundation
import Testing
@testable import Triva

private struct EntryKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func entryStores() throws -> TrivaSharedStores {
    let defaults = try #require(TestDefaults.suite(named: "test.entryPaths.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: defaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
        keyStore: EntryKeyStore()
    )
}

/// Fenêtre qui affiche une conversation de l'historique (stand-in d'une réponse affichée).
@MainActor
private func windowShowingAConversation(stores: TrivaSharedStores) throws -> (TrivaRootCoordinator, ChatViewModel, UUID) {
    stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")
    stores.cloudConsent.grant(providerID: "openai")
    let conversation = try stores.chatHistory.createConversation(title: "En cours")
    let window = TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())
    window.openConversation(id: conversation.id)
    let chat = try #require(window.session.chatViewModel)
    return (window, chat, conversation.id)
}

@MainActor
@Suite("Nouvelle question du système : chaque chemin d'entrée (F3)")
struct NewQuestionEntryPathsTests {
    // MARK: iPhone et iPad : la route passe par la file, UNE fenêtre la prend

    @Test("Toucher du widget (triva://new) : la fenêtre repart à neuf par le chemin « nouvelle conversation » (+1 clavier)")
    func widgetTapURL() throws {
        let (window, chat, _) = try windowShowingAConversation(stores: try entryStores())
        let center = SystemRouteCenter(windowLauncher: nil)
        let before = chat.userNewConversationCount
        // L'URL que pose le widget (`QuickSearchContent.newQuestionURL`).
        let url = try #require(TrivaURLRoute.url(for: .newQuestion(.keyboard)))

        #expect(center.open(url: url))
        window.consumeSystemRoutes(from: center, canUseOtherWindows: false, openInWindow: { _ in })

        #expect(chat.currentConversationID == nil)
        #expect(chat.userNewConversationCount == before + 1)
        #expect(window.selection == .search)
    }

    @Test("Siri, Raccourcis, bouton Action, Centre de contrôle (OpenComposerIntent) : même route, même chemin")
    func openComposerIntentPath() throws {
        let (window, chat, _) = try windowShowingAConversation(stores: try entryStores())
        let center = SystemRouteCenter(windowLauncher: nil)
        let dispatcher = SystemRouteDispatcher()
        dispatcher.install { center.submit($0) }
        let before = chat.userNewConversationCount

        // Ce que fait `OpenComposerIntent.perform()` : `SystemRouteDispatcher.submit(.newQuestion(target.kind))`.
        dispatcher.submit(.newQuestion(ComposerEntryAppEnum.keyboard.kind))
        window.consumeSystemRoutes(from: center, canUseOtherWindows: false, openInWindow: { _ in })

        #expect(chat.currentConversationID == nil)
        #expect(chat.userNewConversationCount == before + 1)
    }

    @Test("Lancement à froid : la route attend le routeur, puis part dans le même chemin")
    func coldLaunchPath() throws {
        let (window, chat, _) = try windowShowingAConversation(stores: try entryStores())
        let center = SystemRouteCenter(windowLauncher: nil)
        let dispatcher = SystemRouteDispatcher()
        dispatcher.submit(.newQuestion(.keyboard))  // l'intent s'exécute AVANT le branchement du routeur
        #expect(dispatcher.bufferedCount == 1)
        dispatcher.install { center.submit($0) }
        let before = chat.userNewConversationCount

        window.consumeSystemRoutes(from: center, canUseOtherWindows: false, openInWindow: { _ in })

        #expect(chat.userNewConversationCount == before + 1)
        #expect(chat.currentConversationID == nil)
    }

    // MARK: Mac : une fenêtre neuve s'ouvre à côté, la fenêtre qui répond n'est pas touchée

    @Test("Mac, widget / Siri / Raccourcis / bouton : une recherche neuve s'ouvre dans une AUTRE fenêtre, la réponse en cours n'est pas touchée")
    func macOpensANewWindow() throws {
        let (_, chat, conversationID) = try windowShowingAConversation(stores: try entryStores())
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)
        let before = chat.userNewConversationCount

        center.submit(.newQuestion(.keyboard))

        let targets = launcher.drain()
        #expect(targets.count == 1)
        if case .newSearch = try #require(targets.first) {} else { Issue.record("une recherche neuve était attendue : \(targets)") }
        #expect(chat.currentConversationID == conversationID, "la fenêtre qui répond garde son fil")
        #expect(chat.userNewConversationCount == before)
    }

    @Test("Barre des menus (Mac) : la question tapée est livrée à la fenêtre NEUVE seulement, jamais à celle qui répond")
    func menuBarQueryGoesToTheNewWindowOnly() throws {
        let stores = try entryStores()
        let (answering, chat, conversationID) = try windowShowingAConversation(stores: stores)
        let launcher = ExternalSearchLauncher()
        answering.session.draft.text = "brouillon en cours"

        #expect(launcher.requestSearch(question: "Une nouvelle question", origin: .typedInMenuBar))
        let target = try #require(launcher.drain().first)
        guard case .newSearch = target else { Issue.record("cible inattendue : \(target)"); return }

        // La fenêtre qui répond n'est pas la cible : elle ne prend rien.
        #expect(answering.deliverExternalQuery(from: launcher.inbox) == .none)
        #expect(answering.session.draft.text == "brouillon en cours")
        #expect(chat.currentConversationID == conversationID)
        #expect(chat.userNewConversationCount == 0)

        // La fenêtre ouverte sur cette cible la prend.
        let fresh = TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())
        fresh.windowTarget = target
        #expect(fresh.deliverExternalQuery(from: launcher.inbox) != .none)
    }

    @Test("Dock et Service « Rechercher avec Triva » : même file de fenêtres neuves, une question sélectionnée reste un brouillon")
    func dockAndServiceOpenNewWindows() throws {
        let launcher = ExternalSearchLauncher()
        launcher.requestNewSearch()
        #expect(launcher.requestSearch(question: "Texte sélectionné", origin: .draft))
        let targets = launcher.drain()
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { if case .newSearch = $0 { true } else { false } })
    }

    // MARK: Siri et Raccourcis avec une question : une session à part

    @Test("« Poser une question à Triva » : session sans fenêtre, jamais celle de la fenêtre qui répond, jamais de reprise automatique")
    func askTrivaUsesItsOwnSession() throws {
        let stores = try entryStores()
        stores.engineSettings.selectedOption = .appleIntelligence
        let (window, windowChat, _) = try windowShowingAConversation(stores: stores)

        let setup = HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil, noticeAcknowledged: true, platform: .iOS)

        let session = try #require(setup.session)
        let headlessChat = try #require(session.chatViewModel)
        #expect(session !== window.session)
        #expect(headlessChat !== windowChat)
        #expect(headlessChat.resumesAfterBackgroundInterruption == false)
        #expect(windowChat.resumesAfterBackgroundInterruption == true)
    }
}
