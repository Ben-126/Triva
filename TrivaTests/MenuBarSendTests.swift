//
//  MenuBarSendTests.swift
//  TrivaTests
//
//  Mission F3 : la question TAPÉE dans le panneau de la barre des menus est envoyée par la fenêtre qui s'ouvre
//  (accord « IA cloud » demandé avant tout envoi) ; ce qui vient d'ailleurs (Service, partage, dépôt) reste un
//  brouillon, jamais envoyé.
//

import Foundation
import Testing
@testable import Triva

private struct SendKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func sendStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.menuBarSend.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: SendKeyStore()
    )
}

/// Fenêtre sur un moteur cloud AVEC fournisseur choisi (donc prête à envoyer), accord donné ou non.
@MainActor
private func cloudWindow(consentGranted: Bool) throws -> TrivaRootCoordinator {
    let stores = try sendStores()
    stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")
    if consentGranted { stores.cloudConsent.grant(providerID: "openai") }
    return TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())
}

/// La fenêtre telle que SwiftUI la crée pour une demande de l'extérieur : cible `.newSearch(id)` du dépôt.
@MainActor
private func receiveFromMenuBar(
    _ question: String,
    origin: ExternalQueryOrigin,
    in window: TrivaRootCoordinator
) -> ExternalQueryOutcome {
    let launcher = ExternalSearchLauncher()
    #expect(launcher.requestSearch(question: question, origin: origin))
    guard case .newSearch(let id) = launcher.drain().first else {
        Issue.record("Une recherche neuve était attendue")
        return .none
    }
    window.restoreWindowTarget(.newSearch(id))
    return window.deliverExternalQuery(from: launcher.inbox)
}

@MainActor
@Suite("Barre des menus — envoi direct de la question tapée")
struct MenuBarSendTests {
    @Test("Question tapée dans le panneau, accord cloud déjà donné : elle part, la barre de saisie est vidée")
    func typedQuestionIsSent() throws {
        let window = try cloudWindow(consentGranted: true)

        let outcome = receiveFromMenuBar("Pourquoi le ciel est bleu ?", origin: .typedInMenuBar, in: window)

        #expect(outcome == .sent)
        #expect(window.session.draft.text.isEmpty)
        #expect(window.selection == .search)
        let chat = try #require(window.session.chatViewModel)
        defer { chat.stop() }
        #expect(chat.pendingConsent == nil)
        #expect(chat.messages.first?.role == .user)
        #expect(chat.messages.first?.text == "Pourquoi le ciel est bleu ?")
    }

    @Test("Moteur cloud sans accord : RIEN ne part, la feuille d'accord attend, la question reste dans la barre de saisie")
    func cloudConsentIsAskedFirst() throws {
        let window = try cloudWindow(consentGranted: false)

        let outcome = receiveFromMenuBar("Question privée", origin: .typedInMenuBar, in: window)

        #expect(outcome == .awaitingConsent)
        let chat = try #require(window.session.chatViewModel)
        #expect(chat.pendingConsent?.action == .send(query: "Question privée"))
        #expect(chat.messages.isEmpty)
        #expect(window.session.draft.text == "Question privée")
    }

    @Test("Accord refusé : la question reste dans la barre de saisie, rien n'est parti")
    func declinedConsentKeepsTheDraft() throws {
        let window = try cloudWindow(consentGranted: false)
        _ = receiveFromMenuBar("À garder", origin: .typedInMenuBar, in: window)
        let chat = try #require(window.session.chatViewModel)

        chat.declinePendingConsent()

        #expect(chat.pendingConsent == nil)
        #expect(chat.messages.isEmpty)
        #expect(window.session.draft.text == "À garder")
    }

    @Test("Texte venu d'AILLEURS (Service, partage, dépôt) : brouillon seulement, jamais envoyé, même accord donné")
    func otherOriginsStayDrafts() throws {
        let window = try cloudWindow(consentGranted: true)

        let outcome = receiveFromMenuBar("Texte sélectionné dans une autre app", origin: .draft, in: window)

        #expect(outcome == .draftPlaced)
        #expect(window.session.draft.text == "Texte sélectionné dans une autre app")
        #expect(window.session.chatViewModel?.messages.isEmpty ?? true)
        #expect(window.selection == .search)
    }

    @Test("Question tapée mais moteur pas prêt (cloud sans fournisseur) : elle reste dans la barre de saisie")
    func notReadyEngineKeepsTheDraft() throws {
        let stores = try sendStores()
        let window = TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())

        let outcome = receiveFromMenuBar("Pas prêt", origin: .typedInMenuBar, in: window)

        #expect(outcome == .draftPlaced)
        #expect(window.session.draft.text == "Pas prêt")
        #expect(window.session.chatViewModel?.messages.isEmpty ?? true)
    }

    @Test("La question n'est remise (donc envoyée) qu'une fois")
    func deliveredOnce() throws {
        let window = try cloudWindow(consentGranted: true)
        let launcher = ExternalSearchLauncher()
        launcher.requestSearch(question: "Une seule fois", origin: .typedInMenuBar)
        guard case .newSearch(let id) = launcher.drain().first else { return }
        window.restoreWindowTarget(.newSearch(id))

        #expect(window.deliverExternalQuery(from: launcher.inbox) == .sent)
        defer { window.session.chatViewModel?.stop() }
        #expect(window.deliverExternalQuery(from: launcher.inbox) == .none)
        #expect(window.session.chatViewModel?.messages.filter { $0.role == .user }.count == 1)
    }
}

@MainActor
@Suite("Barre des menus — origine des questions reçues")
struct ExternalQueryOriginTests {
    @Test("Par défaut une question est un brouillon ; seul le panneau de la barre des menus demande l'envoi")
    func defaultOriginIsDraft() throws {
        let launcher = ExternalSearchLauncher()
        launcher.requestSearch(question: "Service")
        launcher.requestSearch(question: "Panneau", origin: .typedInMenuBar)
        let ids = launcher.drain().compactMap { target -> UUID? in
            if case .newSearch(let id) = target { return id }
            return nil
        }
        #expect(ids.count == 2)
        #expect(launcher.inbox.takeQuery(for: ids[0]) == ExternalQuery(text: "Service", origin: .draft))
        #expect(launcher.inbox.takeQuery(for: ids[1]) == ExternalQuery(text: "Panneau", origin: .typedInMenuBar))
    }

    @Test("Le fournisseur de Services dépose toujours un brouillon")
    func servicesProviderDeposits() throws {
        #if os(macOS)
        let launcher = ExternalSearchLauncher()
        #expect(TrivaServicesProvider(launcher: launcher).deliver(text: "Texte sélectionné") == nil)
        guard case .newSearch(let id) = try #require(launcher.drain().first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        #expect(launcher.inbox.takeQuery(for: id)?.origin == .draft)
        #endif
    }

    @Test("Le texte est assaini quelle que soit l'origine")
    func sanitizedForBothOrigins() throws {
        let launcher = ExternalSearchLauncher()
        launcher.requestSearch(question: "  a\u{0007}b \n", origin: .typedInMenuBar)
        guard case .newSearch(let id) = try #require(launcher.drain().first) else { return }
        #expect(launcher.inbox.takeQuery(for: id)?.text == "ab")
    }
}
