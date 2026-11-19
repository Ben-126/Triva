//
//  ExternalSearchLauncherTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M7) : file des fenêtres demandées de l'extérieur, réception de la question par la fenêtre.
//

import Foundation
import Testing
@testable import Triva

private struct ExternalTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makeExternalCoordinator() throws -> TrivaRootCoordinator {
    let userDefaults = try #require(TestDefaults.suite(named: "test.externalQuery.\(UUID().uuidString)"))
    let stores = TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: ExternalTestKeyStore()
    )
    return TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: WindowConversationRegistry())
}

@MainActor
@Suite("Recherche externe — file des demandes")
struct ExternalSearchLauncherTests {
    @Test("Une question valide ouvre une recherche neuve et attend dans la boîte d'entrée")
    func validQuestion() throws {
        let launcher = ExternalSearchLauncher()
        #expect(launcher.requestSearch(question: "  Qui a inventé le vélo ?  "))
        let targets = launcher.drain()
        #expect(targets.count == 1)
        guard case .newSearch(let id) = try #require(targets.first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        #expect(launcher.inbox.take(for: id) == "Qui a inventé le vélo ?")
    }

    @Test("Vide, espaces ou contrôles : rien n'est ouvert ni déposé")
    func emptyQuestion() {
        let launcher = ExternalSearchLauncher()
        #expect(!launcher.requestSearch(question: nil))
        #expect(!launcher.requestSearch(question: "   \n "))
        #expect(!launcher.requestSearch(question: "\u{0007}\u{0000}"))
        #expect(launcher.revision == 0)
        #expect(launcher.inbox.pendingCount == 0)
        #expect(launcher.drain().isEmpty)
    }

    @Test("Le texte est assaini avant le dépôt (contrôles retirés, longueur bornée)")
    func sanitizedBeforeDeposit() throws {
        let launcher = ExternalSearchLauncher()
        let long = String(repeating: "é", count: ExternalQuerySanitizer.maxLength + 500)
        #expect(launcher.requestSearch(question: "a\u{0007}b" + long))
        guard case .newSearch(let id) = try #require(launcher.drain().first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        let stored = try #require(launcher.inbox.take(for: id))
        #expect(stored.hasPrefix("ab"))
        #expect(stored.count == ExternalQuerySanitizer.maxLength)
    }

    @Test("La cible ne contient jamais le texte de la question")
    func targetHoldsNoQuestionText() throws {
        let launcher = ExternalSearchLauncher()
        launcher.requestSearch(question: "question confidentielle")
        let target = try #require(launcher.drain().first)
        let encoded = try JSONEncoder().encode(target)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("confidentielle"))
    }

    @Test("Nouvelle recherche : chaque demande a une cible différente")
    func newSearchTargetsDiffer() {
        let launcher = ExternalSearchLauncher()
        launcher.requestNewSearch()
        launcher.requestNewSearch()
        let targets = launcher.drain()
        #expect(targets.count == 2)
        #expect(targets[0] != targets[1])
        #expect(launcher.inbox.pendingCount == 0)
    }

    @Test("Une conversation de l'historique se demande par son identifiant")
    func conversationRequest() {
        let launcher = ExternalSearchLauncher()
        let id = UUID()
        launcher.requestConversation(id)
        #expect(launcher.drain() == [.conversation(id)])
    }

    @Test("drain rend chaque cible une seule fois : deux observateurs n'ouvrent pas deux fenêtres")
    func drainOnce() {
        let launcher = ExternalSearchLauncher()
        launcher.requestNewSearch()
        #expect(launcher.drain().count == 1)
        #expect(launcher.drain().isEmpty)
    }

    @Test("revision augmente à chaque demande acceptée, pas à la lecture")
    func revision() {
        let launcher = ExternalSearchLauncher()
        launcher.requestNewSearch()
        launcher.requestConversation(UUID())
        #expect(launcher.revision == 2)
        _ = launcher.drain()
        #expect(launcher.revision == 2)
    }

    @Test("La file est bornée : les plus anciennes demandes sont oubliées")
    func boundedQueue() {
        let launcher = ExternalSearchLauncher()
        let ids = (0..<(ExternalSearchLauncher.maxPending + 3)).map { _ in UUID() }
        ids.forEach { launcher.requestConversation($0) }
        let targets = launcher.drain()
        #expect(targets.count == ExternalSearchLauncher.maxPending)
        #expect(targets.last == .conversation(ids.last!))
        #expect(targets.first == .conversation(ids[3]))
    }

    @Test("Fenêtres affichées : décompte par identifiant, jamais négatif")
    func windowCount() {
        let launcher = ExternalSearchLauncher()
        let first = UUID(), second = UUID()
        launcher.windowDidDisappear(id: first)
        #expect(launcher.visibleWindowCount == 0)
        launcher.windowDidAppear(id: first)
        launcher.windowDidAppear(id: second)
        launcher.windowDidDisappear(id: first)
        #expect(launcher.visibleWindowCount == 1)
    }

    @Test("Une apparition répétée sans disparition ne fait pas dériver le décompte")
    func repeatedAppearanceDoesNotDrift() {
        let launcher = ExternalSearchLauncher()
        let window = UUID()
        launcher.windowDidAppear(id: window)
        launcher.windowDidAppear(id: window)
        launcher.windowDidAppear(id: window)
        #expect(launcher.visibleWindowCount == 1)
        launcher.windowDidDisappear(id: window)
        #expect(launcher.visibleWindowCount == 0)
    }
}

@MainActor
@Suite("Recherche externe — réception par la fenêtre")
struct ExternalQueryReceptionTests {
    @Test("La fenêtre ouverte pour la question la place dans le brouillon, sans l'envoyer")
    func fillsDraft() throws {
        let inbox = ExternalQueryInbox()
        let id = inbox.deposit("Pourquoi le ciel est bleu ?")
        let coordinator = try makeExternalCoordinator()
        coordinator.restoreWindowTarget(.newSearch(id))
        coordinator.selection = .library

        #expect(coordinator.receiveExternalQuery(from: inbox))
        #expect(coordinator.session.draft.text == "Pourquoi le ciel est bleu ?")
        #expect(coordinator.selection == .search)
        #expect(coordinator.session.chatViewModel?.messages.isEmpty ?? true)
    }

    @Test("La question n'est remise qu'une fois")
    func onlyOnce() throws {
        let inbox = ExternalQueryInbox()
        let id = inbox.deposit("Une fois")
        let coordinator = try makeExternalCoordinator()
        coordinator.restoreWindowTarget(.newSearch(id))
        #expect(coordinator.receiveExternalQuery(from: inbox))
        coordinator.session.draft.text = ""
        #expect(!coordinator.receiveExternalQuery(from: inbox))
        #expect(coordinator.session.draft.text.isEmpty)
    }

    @Test("Fenêtre restaurée (identifiant sans dépôt), conversation ou boîte absente : brouillon intact")
    func nothingToReceive() throws {
        let inbox = ExternalQueryInbox()
        let coordinator = try makeExternalCoordinator()
        coordinator.session.draft.text = "à garder"

        coordinator.restoreWindowTarget(.newSearch(UUID()))
        #expect(!coordinator.receiveExternalQuery(from: inbox))
        #expect(!coordinator.receiveExternalQuery(from: nil))

        let id = inbox.deposit("autre fenêtre")
        coordinator.restoreWindowTarget(.conversation(UUID()))
        #expect(!coordinator.receiveExternalQuery(from: inbox))
        #expect(inbox.take(for: id) == "autre fenêtre")
        #expect(coordinator.session.draft.text == "à garder")
    }
}

@MainActor
@Suite("Barre des menus — données du panneau")
struct MenuBarPanelDataTests {
    @Test("Au plus cinq conversations, titre vide remplacé")
    func recentLimit() {
        let conversations = (0..<8).map { index in
            StoredConversation(title: index == 1 ? "   " : "Titre \(index)", createdAt: .now, updatedAt: .now)
        }
        let recent = MenuBarRecentConversation.recent(from: conversations)
        #expect(recent.count == MenuBarRecentConversation.maxCount)
        #expect(recent[0].title == "Titre 0")
        #expect(recent[1].title == MenuBarRecentConversation.untitled)
        #expect(recent.map(\.id) == conversations.prefix(5).map(\.id))
    }

    @Test("L'icône de la barre des menus est désactivée par défaut")
    func offByDefault() throws {
        let defaults = try #require(TestDefaults.suite(named: "test.menuBar.\(UUID().uuidString)"))
        #expect(MenuBarItemPreference.defaultValue == false)
        #expect(!MenuBarItemPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: MenuBarItemPreference.defaultsKey)
        #expect(MenuBarItemPreference.isEnabled(in: defaults))
    }
}
