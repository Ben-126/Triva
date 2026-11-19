//
//  TrivaCommandsTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M4) : ce que font les items de la barre de menus, sans interface.
//

import Foundation
import SwiftUI
import Testing
@testable import Triva

private struct CommandsTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makeCommandsStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.commands.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: CommandsTestKeyStore()
    )
}

@MainActor
private func makeCommandsCoordinator(_ stores: TrivaSharedStores) -> TrivaRootCoordinator {
    TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: WindowConversationRegistry())
}

@MainActor
private func saveCommandsConversation(in stores: TrivaSharedStores) throws -> UUID {
    let conversation = try stores.chatHistory.createConversation(firstQuestion: "Quelle heure est-il ?")
    try stores.chatHistory.appendUserMessage(to: conversation, text: "Quelle heure est-il ?")
    try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Il est 9 h.")
    return conversation.id
}

@MainActor
@Suite("Commandes — table des raccourcis")
struct TrivaCommandTableTests {
    @Test("Chaque item de menu a son entrée dans le catalogue, avec un raccourci SwiftUI")
    func everyCommandIsInTheCatalog() {
        for id in TrivaCommandID.all {
            let shortcut = TrivaShortcutCatalog.shortcut(id: id)
            #expect(shortcut != nil, "\(id) absent du catalogue")
            #expect(shortcut?.keyboardShortcut != nil, "\(id) sans raccourci SwiftUI")
            #expect(shortcut?.source == .menu, "\(id) devrait être déclaré dans le menu")
        }
    }

    @Test("Aucun identifiant de menu en double")
    func commandIDsAreUnique() {
        #expect(Set(TrivaCommandID.all).count == TrivaCommandID.all.count)
    }

    @Test("⇧⌘O, ⌘N et ⌘, : les raccourcis décidés par le chef")
    func decidedShortcuts() throws {
        let newConversation = try #require(TrivaShortcutCatalog.shortcut(id: TrivaCommandID.newConversation)?.keyboardShortcut)
        #expect(newConversation == KeyboardShortcut("o", modifiers: [.command, .shift]))
        let newSearch = try #require(TrivaShortcutCatalog.shortcut(id: TrivaCommandID.newSearch)?.keyboardShortcut)
        #expect(newSearch == KeyboardShortcut("n", modifiers: .command))
        let attach = try #require(TrivaShortcutCatalog.shortcut(id: TrivaCommandID.attach)?.keyboardShortcut)
        #expect(attach == KeyboardShortcut("a", modifiers: [.command, .shift]))
        let stop = try #require(TrivaShortcutCatalog.shortcut(id: TrivaCommandID.stop)?.keyboardShortcut)
        #expect(stop == KeyboardShortcut(".", modifiers: .command))
    }

    @Test("Conversion : modificateurs et touches nommées")
    func conversion() {
        let named = TrivaShortcut(id: "t", title: "t", key: "escape", modifiers: [.option, .control],
                                  platforms: .mac, context: .global, source: .menu)
        #expect(named.keyboardShortcut == KeyboardShortcut(.escape, modifiers: [.option, .control]))
        let unknown = TrivaShortcut(id: "t", title: "t", key: "abc", modifiers: [], platforms: .mac,
                                    context: .global, source: .menu)
        #expect(unknown.keyboardShortcut == nil)
    }

    @Test("Les raccourcis des menus ne se télescopent pas et ne masquent pas le système")
    func catalogStaysSane() {
        #expect(TrivaShortcutCatalog.conflicts().isEmpty)
        #expect(TrivaShortcutCatalog.systemShadowing().isEmpty)
    }
}

@MainActor
@Suite("Commandes — actions sur la fenêtre")
struct TrivaRootCoordinatorCommandsTests {
    @Test("Aller > …  : ⌘1 à ⌘4 changent la destination")
    func goTo() throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        for destination in [TrivaRootDestination.library, .favorites, .discover, .search] {
            coordinator.go(to: destination)
            #expect(coordinator.selection == destination)
        }
    }

    @Test("Fil vide : « Nouvelle conversation » et « Copier la réponse » sont grisés, ⇧⌘O n'agit pas")
    func emptyThread() throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        #expect(!coordinator.canStartNewConversation)
        #expect(coordinator.copyableAnswerText == nil)
        coordinator.go(to: .library)
        coordinator.startNewConversationFromMenu()
        #expect(coordinator.selection == .library)
    }

    @Test("Aucune génération : « Arrêter la réponse » est grisé et sans effet")
    func nothingToStop() throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        #expect(!coordinator.canStopGeneration)
        coordinator.stopGeneration()
        #expect(!coordinator.canStopGeneration)
    }

    @Test("⇧⌘O depuis la Bibliothèque : retour à la Recherche, fil vidé, demande comptée pour la vue")
    func newConversationFromMenu() throws {
        let stores = try makeCommandsStores()
        let coordinator = makeCommandsCoordinator(stores)
        coordinator.openConversation(id: try saveCommandsConversation(in: stores))
        let viewModel = try #require(coordinator.session.chatViewModel)
        #expect(coordinator.canStartNewConversation)
        coordinator.go(to: .library)

        coordinator.startNewConversationFromMenu()

        #expect(coordinator.selection == .search)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)
        #expect(viewModel.userNewConversationCount == 1)
        #expect(!coordinator.canStartNewConversation)
    }

    @Test("Seule une demande de l'utilisateur est comptée : une remise à zéro automatique n'ouvre pas le clavier")
    func automaticResetIsNotCounted() throws {
        let stores = try makeCommandsStores()
        let coordinator = makeCommandsCoordinator(stores)
        let id = try saveCommandsConversation(in: stores)
        coordinator.openConversation(id: id)
        let viewModel = try #require(coordinator.session.chatViewModel)
        viewModel.conversationWasDeleted(id: id)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.userNewConversationCount == 0)
    }

    @Test("⇧⌘C copie la dernière réponse terminée, marquée « générée par IA », sans toucher au vrai presse-papiers")
    func copyLastAnswer() throws {
        let stores = try makeCommandsStores()
        let coordinator = makeCommandsCoordinator(stores)
        coordinator.openConversation(id: try saveCommandsConversation(in: stores))
        var written: [String] = []
        #expect(coordinator.copyLastAnswer { written.append($0) })
        let text = try #require(written.first)
        #expect(text.contains("Il est 9 h."))
        #expect(text == AIGeneratedMarking.marked("Il est 9 h."))
    }

    @Test("Une réponse en cours, arrêtée ou en échec ne se copie pas ; la dernière réponse fait foi")
    func copyableAnswerRules() {
        let user = ChatViewModel.Message(role: .user, text: "Question")
        var done = ChatViewModel.Message(role: .assistant, text: "Première réponse")
        done.finish(.completed, at: Date(timeIntervalSince1970: 0))
        #expect(TrivaRootCoordinator.copyableAnswerText(in: [user, done])?.contains("Première réponse") == true)

        let streaming = ChatViewModel.Message(role: .assistant, text: "En cours", isStreaming: true)
        #expect(TrivaRootCoordinator.copyableAnswerText(in: [user, done, user, streaming]) == nil)

        var interrupted = ChatViewModel.Message(role: .assistant, text: "Partiel")
        interrupted.finish(.interrupted, at: Date(timeIntervalSince1970: 0))
        #expect(TrivaRootCoordinator.copyableAnswerText(in: [user, interrupted]) == nil)

        var failed = ChatViewModel.Message(role: .assistant, text: "Échec")
        failed.finish(.failed, at: Date(timeIntervalSince1970: 0))
        #expect(TrivaRootCoordinator.copyableAnswerText(in: [user, failed]) == nil)

        #expect(TrivaRootCoordinator.copyableAnswerText(in: []) == nil)
        #expect(TrivaRootCoordinator.copyableAnswerText(in: [user]) == nil)
    }

    @Test("⌘F : Bibliothèque et demande de focus du champ de recherche")
    func historySearch() throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        #expect(!coordinator.isHistorySearchRequested)
        coordinator.requestHistorySearch()
        #expect(coordinator.selection == .library)
        #expect(coordinator.isHistorySearchRequested)
    }

    @Test("⇧⌘A depuis la Recherche : le sélecteur s'ouvre aussitôt")
    func attachFromSearch() throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        coordinator.requestAttachFiles()
        let controller = try #require(coordinator.session.chatViewModel?.attachmentController)
        #expect(controller.isPickerPresented)
        #expect(coordinator.selection == .search)
    }

    @Test("⇧⌘A depuis une autre destination : retour à la Recherche, puis le sélecteur s'ouvre")
    func attachFromElsewhere() async throws {
        let coordinator = makeCommandsCoordinator(try makeCommandsStores())
        coordinator.go(to: .favorites)
        coordinator.requestAttachFiles()
        #expect(coordinator.selection == .search)
        let controller = try #require(coordinator.session.chatViewModel?.attachmentController)
        for _ in 0..<40 where !controller.isPickerPresented {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.isPickerPresented)
    }
}

@MainActor
@Suite("Commandes — sélecteur de fichiers")
struct FileAttachmentRequestTests {
    @Test("requestPicker ouvre le sélecteur tant qu'on peut joindre")
    func opensWhenPossible() {
        let controller = FileAttachmentController(store: AttachmentStore())
        controller.requestPicker()
        #expect(controller.isPickerPresented)
        #expect(controller.notices.isEmpty)
    }

    @Test("Limite de fichiers atteinte : pas de sélecteur, une explication")
    func explainsWhenFull() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TrivaCommandsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = FileAttachmentController(store: AttachmentStore(), maxAttachmentCount: 1)
        let file = directory.appending(path: "a.txt")
        try "contenu".write(to: file, atomically: true, encoding: .utf8)
        controller.enqueue([file])
        // Le fichier en file occupe déjà l'unique emplacement : plus rien à joindre.
        #expect(!controller.canAttachMore)
        controller.requestPicker()
        #expect(!controller.isPickerPresented)
        #expect(!controller.notices.isEmpty)
    }
}
