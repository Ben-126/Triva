//
//  DuoStatePreservationTests.swift
//  TrivaTests
//
//  Mission I1 (2.0, iPhone Duo) : plier ou déplier remplace les vues ; ce qui doit survivre vit au-dessus
//  d'elles (SearchSession, TrivaRootCoordinator, ChatViewModel, DiscoverViewModel).
//

import SwiftUI
import Testing
@testable import Triva

private struct DuoTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { "sk-test" }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makeDuoStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.duoState.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: DuoTestKeyStore()
    )
}

/// Accord cloud simulé : la demande revient tant que l'accord n'est pas donné.
@MainActor
private final class ConsentGate {
    let request = CloudAIConsentCatalog.request(providerID: "openai", customPresets: [])!
    private(set) var grantedProviderIDs: [String] = []
    var isGranted: Bool { !grantedProviderIDs.isEmpty }
    func resolve() -> CloudAIConsentRequest? { isGranted ? nil : request }
    func grant(_ request: CloudAIConsentRequest) { grantedProviderIDs.append(request.providerID) }
}

extension ChatViewModelTests {
    fileprivate func makeConsentViewModel(provider: any AIGenerating, gate: ConsentGate) -> ChatViewModel {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        return ChatViewModel(
            resolveProvider: { provider },
            resolveFailoverManager: { failoverManager },
            makeOrchestrator: { inputs in Self.deterministicOrchestrator(inputs) },
            generateSuggestions: { _, _ in [] },
            makeMediaSearcher: { _ in RecordingMediaSearcher() },
            resolveConsentRequest: { gate.resolve() },
            grantConsent: { gate.grant($0) }
        )
    }
}

@MainActor
@Suite("Duo — consentement cloud en attente tenu par le modèle")
struct DuoPendingConsentTests {
    private let base = ChatViewModelTests()

    @Test("Un envoi qui demande le consentement est gardé en DONNÉES : rien n'est parti, la demande reste")
    func pendingConsentIsKeptInTheModel() {
        let gate = ConsentGate()
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)

        let needsSheet = viewModel.requestConsent(resuming: .send(query: "Quelle heure à Tokyo ?"))

        #expect(needsSheet)
        #expect(viewModel.pendingConsent?.request == gate.request)
        #expect(viewModel.pendingConsent?.action == .send(query: "Quelle heure à Tokyo ?"))
        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
    }

    @Test("L'attente survit à la reconstruction de la vue : relue telle quelle, puis « Autoriser » reprend l'envoi")
    func allowResumesTheInterruptedSend() async {
        let gate = ConsentGate()
        let provider = ChatViewModelTests.ControllableStreamingAIGenerating()
        let viewModel = base.makeConsentViewModel(provider: provider, gate: gate)
        #expect(viewModel.requestConsent(resuming: .send(query: "question en attente")))

        // La vue est remplacée ici : une nouvelle `ChatView` relit `pendingConsent` du modèle.
        #expect(viewModel.pendingConsent?.action == .send(query: "question en attente"))

        let resumed = viewModel.allowPendingConsent()

        #expect(resumed == .send(query: "question en attente"))
        #expect(gate.grantedProviderIDs == ["openai"])
        #expect(viewModel.pendingConsent == nil)
        #expect(viewModel.messages.first?.text == "question en attente")
        #expect(viewModel.isGenerating)
        viewModel.stop()
        await base.waitUntil("échange arrêté") { !viewModel.isGenerating }
    }

    @Test("« Annuler » : rien n'est envoyé, message clair, attente vidée")
    func declineClearsTheWait() {
        let gate = ConsentGate()
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)
        #expect(viewModel.requestConsent(resuming: .suggestion("une piste")))

        viewModel.declinePendingConsent()

        #expect(viewModel.pendingConsent == nil)
        #expect(viewModel.errorDescription == CloudAIConsentText.cancelled)
        #expect(viewModel.messages.isEmpty)
        #expect(gate.grantedProviderIDs.isEmpty)
        // Idempotent : la fermeture de la feuille rappelle la même action.
        viewModel.declinePendingConsent()
        #expect(viewModel.errorDescription == CloudAIConsentText.cancelled)
    }

    @Test("Sans demande à faire : l'appelant envoie tout de suite, rien n'est mémorisé")
    func noRequestNeeded() {
        let gate = ConsentGate()
        gate.grant(gate.request)
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)

        #expect(!viewModel.requestConsent(resuming: .send(query: "x")))
        #expect(viewModel.pendingConsent == nil)
        #expect(viewModel.allowPendingConsent() == nil)
    }

    @Test("Les cinq envois sont gardés tels quels", arguments: [
        PendingSendAction.send(query: "q"),
        .suggestion("s"),
        .retryInQuickMode(messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        .regenerateWithReadPages,
        .retryAfterOffline(quickMode: true),
    ])
    func everyActionIsKept(action: PendingSendAction) {
        let gate = ConsentGate()
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)

        #expect(viewModel.requestConsent(resuming: action))
        #expect(viewModel.pendingConsent?.action == action)
    }

    @Test("Une génération en cours n'est liée à aucune vue : le modèle la poursuit seul jusqu'au bout")
    func generationIsOwnedByTheModel() async {
        let provider = ChatViewModelTests.ControllableStreamingAIGenerating()
        let viewModel = base.makeViewModel(resolveProvider: { provider })

        viewModel.startSend(query: "première")
        guard let continuation = await base.waitForContinuation(provider) else { return }
        continuation.yield("Voici un début")
        await base.waitUntil("1er snapshot reflété") { viewModel.messages.last?.text == "Voici un début" }

        // Aucune vue n'existe dans ce test : la génération avance quand même, et se termine.
        #expect(viewModel.isGenerating)
        continuation.yield("Voici un début et la fin.")
        continuation.finish()
        await base.waitUntil("échange terminé") { !viewModel.isGenerating }
        #expect(viewModel.messages.last?.text == "Voici un début et la fin.")
    }

    @Test("Deux demandes de consentement de suite : la seconde remplace la première, « Autoriser » reprend la dernière")
    func secondRequestReplacesTheFirst() async {
        let gate = ConsentGate()
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)
        #expect(viewModel.requestConsent(resuming: .send(query: "première")))
        #expect(viewModel.requestConsent(resuming: .send(query: "seconde")))

        #expect(viewModel.pendingConsent?.action == .send(query: "seconde"))
        #expect(viewModel.allowPendingConsent() == .send(query: "seconde"))
        #expect(viewModel.messages.first?.text == "seconde")
        #expect(!viewModel.messages.contains { $0.text == "première" })
        viewModel.stop()
        await base.waitUntil("échange arrêté") { !viewModel.isGenerating }
    }

    @Test("« Annuler » après « Nouvelle conversation » : l'attente est vidée et rien n'est envoyé")
    func declineAfterNewConversation() {
        let gate = ConsentGate()
        let viewModel = base.makeConsentViewModel(provider: ChatViewModelTests.ControllableStreamingAIGenerating(), gate: gate)
        #expect(viewModel.requestConsent(resuming: .send(query: "en attente")))

        viewModel.startNewConversation()
        viewModel.declinePendingConsent()

        #expect(viewModel.pendingConsent == nil)
        #expect(viewModel.messages.isEmpty)
        #expect(gate.grantedProviderIDs.isEmpty)
    }
}

@MainActor
@Suite("Duo — l'état de la fenêtre survit aux actions entre espaces")
struct DuoWindowStateTests {
    // Plier l'iPhone Duo démonte la destination affichée ; ce qui doit survivre est tenu par le coordinateur.
    // Ces tests font ce que fait l'utilisateur pendant que la vue est démontée (changer d'espace, chercher depuis
    // Découvrir, supprimer une conversation) et vérifient que l'état « de vue » n'est pas réinitialisé au passage.

    @Test("Favori ouvert : survit à un passage par un autre espace et au retour")
    func favoritesStateSurvivesDestinationChanges() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeDuoStores())
        let messageID = UUID()
        coordinator.selection = .favorites
        coordinator.favoritesPath.append(FavoriteRoute(messageID: messageID))
        coordinator.favoritesSelection = messageID

        coordinator.selection = .library
        coordinator.search(DiscoverArticle(topic: .tech, title: "Un titre", url: "https://example.org/a", snippet: nil, imageURL: nil))
        coordinator.selection = .favorites

        #expect(coordinator.favoritesPath.count == 1)
        #expect(coordinator.favoritesSelection == messageID)
    }

    @Test("Feuille et moteur en attente des Réglages : les raccourcis vers les Réglages ne touchent qu'à la pile")
    func settingsSheetSurvivesShortcuts() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeDuoStores())
        coordinator.settingsSheet = .apiKeys
        coordinator.settingsPendingEngine = .mlxLocal

        coordinator.showSettings()
        coordinator.showSearchKeys()

        #expect(coordinator.settingsSheet == .apiKeys)
        #expect(coordinator.settingsPendingEngine == .mlxLocal)
        #expect(coordinator.settingsPath.count == 1)
        #expect(coordinator.selection == .settings)
    }

    @Test("Sujets dépliés de Découvrir : « Chercher dans Triva » ne les replie pas")
    func expandedTopicsSurviveASearch() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makeDuoStores())
        let topic = try #require(DiscoverTopic.allCases.first)
        coordinator.discover.expandedTopics.insert(topic)

        coordinator.search(DiscoverArticle(topic: .tech, title: "Un titre", url: "https://example.org/a", snippet: nil, imageURL: nil))

        #expect(coordinator.discover.expandedTopics == [topic])
        #expect(coordinator.selection == .search)
    }

    @Test("Brouillon et position de lecture : « Nouvelle conversation » garde le brouillon et efface la réponse ciblée")
    func newConversationKeepsTheDraft() throws {
        let session = SearchSession(engine: .appleIntelligence, stores: try makeDuoStores())
        session.draft.text = "à garder"
        let answerID = UUID()
        session.transcriptScroll.noteLastAnswer(answerID)
        session.transcriptScroll.focusedAnswerID = answerID
        session.ensureChatViewModel()

        session.chatViewModel?.startNewConversation()
        session.transcriptScroll.noteLastAnswer(nil)

        #expect(session.draft.text == "à garder")
        #expect(session.transcriptScroll.focusedAnswerID == nil)
    }

    @Test("ensureChatViewModel() rappelé ne recrée pas le modèle (la conversation survit au remontage)")
    func ensureChatViewModelIsStable() throws {
        let session = SearchSession(engine: .appleIntelligence, stores: try makeDuoStores())
        session.ensureChatViewModel()
        let first = try #require(session.chatViewModel)

        session.ensureChatViewModel()

        #expect(session.chatViewModel === first)
    }
}

@MainActor
@Suite("Duo — position de lecture du fil")
struct TranscriptScrollStateTests {
    private let conversation = UUID()
    private let message = UUID()

    @Test("Même conversation, lecteur en bas : on reste en bas")
    func pinnedStaysAtBottom() {
        let action = TranscriptScrollState.appearanceAction(
            currentConversationID: conversation, lastPositionedConversationID: conversation,
            isPinnedToBottom: true, anchorMessageID: message
        )
        #expect(action == .stayAtBottom)
    }

    @Test("Même conversation, lecteur remonté : retour au message gardé")
    func scrolledUpRestores() {
        let action = TranscriptScrollState.appearanceAction(
            currentConversationID: conversation, lastPositionedConversationID: conversation,
            isPinnedToBottom: false, anchorMessageID: message
        )
        #expect(action == .restore(messageID: message))
    }

    @Test("Remonté mais aucun message gardé : en bas")
    func scrolledUpWithoutAnchor() {
        let action = TranscriptScrollState.appearanceAction(
            currentConversationID: conversation, lastPositionedConversationID: conversation,
            isPinnedToBottom: false, anchorMessageID: nil
        )
        #expect(action == .stayAtBottom)
    }

    @Test("Autre conversation (rouverte depuis la Bibliothèque) : début de la dernière réponse, comme avant")
    func otherConversationShowsAnswerStart() {
        let action = TranscriptScrollState.appearanceAction(
            currentConversationID: conversation, lastPositionedConversationID: UUID(),
            isPinnedToBottom: false, anchorMessageID: message
        )
        #expect(action == .showLastAnswerStart)
    }

    @Test("Premier affichage d'une conversation vierge : rien à positionner")
    func firstAppearanceOfABlankConversation() {
        let action = TranscriptScrollState.appearanceAction(
            currentConversationID: nil, lastPositionedConversationID: nil,
            isPinnedToBottom: true, anchorMessageID: nil
        )
        #expect(action == .stayAtBottom)
    }

    @Test("Le message en haut de la zone visible est le dernier dont le haut est passé")
    func topVisibleMessage() {
        let a = UUID(), b = UUID(), c = UUID()
        let tops: [UUID: CGFloat] = [a: 24, b: 300, c: 700]
        let ids = [a, b, c]

        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: ids, rowTops: tops, offsetY: 0) == a)
        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: ids, rowTops: tops, offsetY: 300) == b)
        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: ids, rowTops: tops, offsetY: 650) == b)
        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: ids, rowTops: tops, offsetY: 5_000) == c)
        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: ids, rowTops: [:], offsetY: 100) == nil)
        #expect(TranscriptScrollState.topVisibleMessage(orderedIDs: [], rowTops: tops, offsetY: 100) == nil)
    }

    @Test("recordPosition range le message dans l'état de la session")
    func recordPositionStoresTheAnchor() {
        let state = TranscriptScrollState()
        let a = UUID(), b = UUID()
        state.rowTops = [a: 24, b: 500]

        state.recordPosition(orderedIDs: [a, b], offsetY: 520)

        #expect(state.anchorMessageID == b)
    }

    @Test("Identifiant de défilement : la question garde son UUID, la réponse son début de réponse")
    func scrollIDsMatchTheRows() {
        let id = UUID()

        #expect(ChatTranscriptRow.scrollID(messageID: id, isAnswer: false) == id.uuidString)
        #expect(ChatTranscriptRow.scrollID(messageID: id, isAnswer: true) == ChatTranscriptRow.answerStartID(id))
    }
}
