//
//  X2ChatZoneTests.swift
//  TrivaTests
//
//  Mission W4-X2 : correctifs de la zone Recherche / fenêtres (C1, M7, R2-01, R2-02, R2-03, R2-11, R2-19).
//

import Foundation
import SwiftUI
import Testing
@testable import Triva

private struct X2KeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func x2Stores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.x2.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: X2KeyStore()
    )
}

/// Moteur cloud avec fournisseur, accord donné ou non.
@MainActor
private func x2Window(
    stores: TrivaSharedStores? = nil,
    consent: Bool,
    engine: AIEngineOption = .cloudBYOK,
    registry: WindowConversationRegistry = WindowConversationRegistry()
) throws -> TrivaRootCoordinator {
    let stores = try stores ?? x2Stores()
    stores.cloudSelection.selection = CloudProviderSelection(providerID: "openai", model: "gpt-test")
    if consent { stores.cloudConsent.grant(providerID: "openai") }
    return TrivaRootCoordinator(engine: engine, stores: stores, windowRegistry: registry)
}

@MainActor
private func x2Center() -> SystemRouteCenter {
    SystemRouteCenter(windowLauncher: nil, depositRoot: FileManager.default.temporaryDirectory.appendingPathComponent("X2Center-\(UUID().uuidString)"))
}

// MARK: - C1 : l'accord cloud en attente ne survit pas à un changement de fil

@MainActor
@Suite("C1 — accord cloud en attente et changement de fil")
struct X2PendingConsentTests {
    @Test("Nouvelle conversation (route système) : l'attente d'accord est annulée, la question n'est jamais envoyée")
    func newConversationCancelsThePendingConsent() throws {
        let window = try x2Window(consent: false)
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        #expect(chat.requestConsent(resuming: .send(query: "question privée")))

        window.apply(.newQuestion(.keyboard))

        #expect(chat.pendingConsent == nil)
        #expect(chat.allowPendingConsent() == nil)
        #expect(chat.messages.isEmpty)
        #expect(!chat.isGenerating)
    }

    @Test("Conversation rouverte par une route : l'attente d'accord est annulée, rien n'est envoyé dans l'autre fil")
    func openingAConversationCancelsThePendingConsent() throws {
        let stores = try x2Stores()
        let other = try stores.chatHistory.createConversation(title: "Autre fil")
        let window = try x2Window(stores: stores, consent: false)
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        #expect(chat.requestConsent(resuming: .send(query: "question en attente")))

        window.apply(.conversation(other.id))

        #expect(chat.currentConversationID == other.id)
        #expect(chat.pendingConsent == nil)
        #expect(chat.allowPendingConsent() == nil)
        #expect(!chat.isGenerating)
    }

    @Test("Nouvelle conversation demandée par l'utilisateur : même effet")
    func userNewConversationCancelsThePendingConsent() throws {
        let window = try x2Window(consent: false)
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        #expect(chat.requestConsent(resuming: .suggestion("une piste")))

        chat.startNewConversationFromUser()

        #expect(chat.pendingConsent == nil)
    }

    @Test("Tant que la feuille d'accord est ouverte, les routes du système attendent : rien n'est appliqué")
    func routesWaitWhileTheConsentSheetIsOpen() throws {
        let window = try x2Window(consent: false)
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        window.session.draft.text = "ma question"
        #expect(chat.requestConsent(resuming: .send(query: "ma question")))
        let center = x2Center()
        center.submit(.draft("Texte partagé"))
        center.submit(.newQuestion(.keyboard))

        let applied = window.consumeSystemRoutes(from: center, canUseOtherWindows: false) { _ in }

        #expect(applied == 0)
        #expect(window.session.draft.text == "ma question")
        #expect(chat.pendingConsent != nil)
        // Les routes sont toujours là : la fenêtre qui prendra la main après la feuille les trouvera.
        #expect(center.drain().count == 2)
    }

    @Test("Feuille refusée : les routes en attente s'appliquent")
    func routesApplyOnceTheSheetIsClosed() throws {
        let window = try x2Window(consent: false)
        window.session.ensureChatViewModel()
        let chat = try #require(window.session.chatViewModel)
        #expect(chat.requestConsent(resuming: .send(query: "q")))
        let center = x2Center()
        center.submit(.draft("Texte partagé"))
        #expect(window.consumeSystemRoutes(from: center, canUseOtherWindows: false) { _ in } == 0)

        chat.declinePendingConsent()
        let applied = window.consumeSystemRoutes(from: center, canUseOtherWindows: false) { _ in }

        #expect(applied == 1)
        #expect(window.session.draft.text == "Texte partagé")
    }

    @Test("Sans attente d'accord, les routes s'appliquent comme avant")
    func routesApplyWithoutPendingConsent() throws {
        let window = try x2Window(consent: true)
        let center = x2Center()
        center.submit(.draft("Bonjour"))

        #expect(window.consumeSystemRoutes(from: center, canUseOtherWindows: false) { _ in } == 1)
        #expect(window.session.draft.text == "Bonjour")
    }
}

// MARK: - M7 / R2-02 : un texte partagé s'ajoute au brouillon

@MainActor
@Suite("M7 / R2-02 — texte partagé ajouté au brouillon")
struct X2DraftRouteTests {
    @Test("Un brouillon en cours n'est pas remplacé : le texte partagé est ajouté à la suite")
    func sharedTextIsAppended() throws {
        let window = try x2Window(consent: true)
        window.session.draft.text = "Ce que je tapais"

        let outcome = window.apply(.draft("Texte partagé"))

        #expect(outcome == .draftPlaced)
        #expect(window.session.draft.text == "Ce que je tapais Texte partagé")
        #expect(window.selection == .search)
    }

    @Test("Brouillon vide : le texte partagé est placé tel quel")
    func sharedTextOnEmptyDraft() throws {
        let window = try x2Window(consent: true)
        window.apply(.draft("  Texte\u{200B} partagé \n"))
        #expect(window.session.draft.text == "Texte partagé")
    }

    @Test("Deux partages de suite : les deux textes sont gardés, dans l'ordre")
    func twoSharesAreBothKept() throws {
        let window = try x2Window(consent: true)
        window.apply(.draft("Premier"))
        window.apply(.draft("Second"))
        #expect(window.session.draft.text == "Premier Second")
    }

    @Test("Texte coupé à la limite : la note « texte coupé » est montrée sous la barre de saisie")
    func truncationIsAnnounced() throws {
        let window = try x2Window(consent: true)
        let long = String(repeating: "mot ", count: ExternalQuerySanitizer.maxLength)

        window.apply(.draft(long))

        let chat = try #require(window.session.chatViewModel)
        #expect(chat.attachmentController.notices.isEmpty == false)
        #expect(window.session.draft.text.count <= ExternalQuerySanitizer.maxLength)
    }

    @Test("Texte court : aucune note")
    func shortTextHasNoNotice() throws {
        let window = try x2Window(consent: true)
        window.apply(.draft("court"))
        #expect(window.session.chatViewModel?.attachmentController.notices.isEmpty ?? true)
    }
}

// MARK: - R2-11 : une route ferme les présentations de la fenêtre

@MainActor
@Suite("R2-11 — les routes du système ferment les présentations")
struct X2PresentationTests {
    @Test("Réglages, choix du modèle local et présentations de la coquille sont fermés avant la route")
    func routeClosesPresentations() throws {
        let window = try x2Window(consent: true)
        window.settingsSheet = .engineSelection
        window.session.isChoosingMLXModel = true
        var closedByShell = 0
        window.dismissShellPresentations = { closedByShell += 1 }

        window.apply(.newQuestion(.keyboard))

        #expect(window.settingsSheet == nil)
        #expect(window.session.isChoosingMLXModel == false)
        #expect(closedByShell == 1)
        #expect(window.selection == .search)
    }

    @Test("Un brouillon illisible ne ferme rien")
    func ignoredRouteClosesNothing() throws {
        let window = try x2Window(consent: true)
        window.settingsSheet = .apiKeys
        var closedByShell = 0
        window.dismissShellPresentations = { closedByShell += 1 }

        #expect(window.apply(.draft(" \u{200B} ")) == .ignored)

        #expect(window.settingsSheet == .apiKeys)
        #expect(closedByShell == 0)
    }

    @Test("Le signal de fermeture avance à chaque route : les écrans locaux (Coup d'œil) le suivent")
    func dismissalSignalAdvances() throws {
        let window = try x2Window(consent: true)
        let before = window.presentationDismissal.epoch
        window.apply(.draft("Bonjour"))
        #expect(window.presentationDismissal.epoch == before + 1)
    }
}

// MARK: - R2-03 : la fenêtre qui tient la conversation l'affiche vraiment

@MainActor
@Suite("R2-03 — ramener la fenêtre qui tient la conversation")
struct X2RevealConversationTests {
    @Test("Fenêtre sur la Bibliothèque : ramenée devant ET placée sur la Recherche")
    func holderOnLibraryIsSentToSearch() throws {
        let stores = try x2Stores()
        let conversation = try stores.chatHistory.createConversation(title: "Tenue")
        let registry = WindowConversationRegistry()
        let holder = try x2Window(stores: stores, consent: true, registry: registry)
        holder.openConversation(id: conversation.id)
        holder.selection = .library
        var focused = false
        registry.setFocusAction({ focused = true; return true }, in: holder.windowID)
        let asker = try x2Window(stores: stores, consent: true, registry: registry)

        asker.openConversationFromHistory(id: conversation.id, canUseOtherWindows: true) { _ in }

        #expect(focused)
        #expect(holder.selection == .search)
        #expect(holder.session.chatViewModel?.currentConversationID == conversation.id)
        #expect(asker.session.chatViewModel?.currentConversationID == nil)
    }

    @Test("Fenêtre qui affiche une autre conversation : elle ouvre celle demandée")
    func holderShowingAnotherConversationSwitches() throws {
        let stores = try x2Stores()
        let wanted = try stores.chatHistory.createConversation(title: "Demandée")
        let shown = try stores.chatHistory.createConversation(title: "Affichée")
        let holder = try x2Window(stores: stores, consent: true)
        holder.openConversation(id: shown.id)
        holder.selection = .library

        holder.revealConversation(wanted.id)

        #expect(holder.selection == .search)
        #expect(holder.session.chatViewModel?.currentConversationID == wanted.id)
    }

    @Test("Conversation déjà affichée : le fil n'est pas rechargé")
    func alreadyDisplayedIsNotReloaded() throws {
        let stores = try x2Stores()
        let conversation = try stores.chatHistory.createConversation(title: "Là")
        let holder = try x2Window(stores: stores, consent: true)
        holder.openConversation(id: conversation.id)
        holder.settingsSheet = .apiKeys

        holder.revealConversation(conversation.id)

        #expect(holder.session.chatViewModel?.currentConversationID == conversation.id)
        #expect(holder.settingsSheet == nil)
    }
}

// MARK: - R2-19 : conversation supprimée ouverte de l'extérieur

@MainActor
@Suite("R2-19 — conversation supprimée ouverte depuis le widget ou Spotlight")
struct X2MissingConversationTests {
    @Test("Ouverture demandée de l'extérieur : le message « n'existe plus » est affiché")
    func externalOpenSaysTheConversationIsGone() throws {
        let window = try x2Window(consent: true)
        let inbox = ExternalQueryInbox()
        let missing = UUID()
        inbox.noteConversationRequested(missing)

        window.restoreWindowTarget(.conversation(missing), externalInbox: inbox)

        #expect(window.session.chatViewModel?.persistenceErrorDescription == ChatViewModel.missingConversationMessage)
        #expect(window.windowTarget.conversationID == nil)
    }

    @Test("Restauration au relancement (aucune demande extérieure) : silencieuse comme avant")
    func relaunchRestorationStaysSilent() throws {
        let window = try x2Window(consent: true)
        let inbox = ExternalQueryInbox()

        window.restoreWindowTarget(.conversation(UUID()), externalInbox: inbox)

        #expect(window.session.chatViewModel?.persistenceErrorDescription == nil)
    }

    @Test("La demande n'est lue qu'une fois et expire")
    func requestIsConsumedOnceAndExpires() {
        let inbox = ExternalQueryInbox()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        inbox.noteConversationRequested(id, at: now)
        #expect(inbox.takeConversationRequest(id, at: now.addingTimeInterval(1)) == true)
        #expect(inbox.takeConversationRequest(id, at: now.addingTimeInterval(2)) == false)

        inbox.noteConversationRequested(id, at: now)
        #expect(inbox.takeConversationRequest(id, at: now.addingTimeInterval(ExternalQueryInbox.requestLifetime + 1)) == false)
    }

    @Test("Le lanceur note la conversation demandée")
    func launcherNotesTheRequest() {
        let launcher = ExternalSearchLauncher()
        let id = UUID()
        launcher.requestConversation(id)
        #expect(launcher.inbox.takeConversationRequest(id) == true)
    }
}

// MARK: - R2-01 puis mission M : MLX ne travaille pas pour le GPU en arrière-plan

/// La décision est désormais celle de l'APP entière (`LocalGPUAccessMonitor`) et plus celle d'une scène : arrêter une
/// réponse à `.background` sans la garer d'abord faisait justement envoyer un tampon refusé.
@MainActor
@Suite("R2-01 — arrêt de la génération locale avant l'arrière-plan")
struct X2BackgroundGPUTests {
    @Test("Une session sait s'arrêter, avec ou sans fil de discussion ouvert")
    func sessionStops() async throws {
        let window = try x2Window(consent: true, engine: .mlxLocal)
        await window.session.stopLocalGenerationInBackground()
        window.session.ensureChatViewModel()
        await window.session.stopLocalGenerationInBackground()
        #expect(window.session.chatViewModel?.isGenerating == false)
    }

    @Test("Relancement : la fenêtre restaurée sur une question restée sans réponse la dit interrompue, sans rien envoyer")
    func restoredWindowMarksTheUnansweredQuestion() throws {
        let stores = try x2Stores()
        let conversation = try stores.chatHistory.createConversation(firstQuestion: "Question coupée")
        try stores.chatHistory.appendUserMessage(to: conversation, text: "Question coupée")
        let window = try x2Window(stores: stores, consent: true, engine: .mlxLocal)

        window.restoreWindowTarget(.conversation(conversation.id))

        let chat = try #require(window.session.chatViewModel)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        let last = try #require(chat.messages.last)
        #expect(last.status == .interrupted)
        #expect(chat.canRetryInterrupted(last))
        #expect(!chat.isGenerating)
        #expect(chat.pendingConsent == nil)
        #expect(try #require(try stores.chatHistory.conversation(with: conversation.id)).orderedMessages.count == 1)
    }

    @Test("La plateforme dit la vérité : iOS restreint le GPU, macOS non")
    func platformFlag() {
        #if os(iOS)
        #expect(LocalGPUGate.platformRestrictsGPU)
        #else
        #expect(!LocalGPUGate.platformRestrictsGPU)
        #endif
    }
}
