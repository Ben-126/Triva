//
//  SearchFallbackPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Ce que le chat montre de la recherche de secours (RI2) : l'invitation quand toutes les sources ont
// échoué, la ligne « Résultats : … » sous les sources. La logique pure d'abord, puis le vrai
// `ChatViewModel` avec son `makeOrchestrator` par défaut. Aucun réseau, aucun modèle système.

private typealias Provider = ScriptedWebSearchProvider

private func failure(_ source: WebSearchSourceKind, _ error: WebSearchError = .unavailable) -> WebSearchSourceFailure {
    WebSearchSourceFailure(source: source, reason: .searchFailed(error))
}

// MARK: - Invitation (logique pure)

@Suite("SearchKeyInvitation — quand inviter à gérer ses clés de recherche")
struct SearchKeyInvitationTests {
    @Test("Toutes les sources en échec, aucune clé personnelle : inviter à en ajouter une")
    func noKeyInTheFailures() throws {
        let error = WebSearchChainError.allSourcesFailed([failure(.searxng), failure(.wikipedia), failure(.marginalia)])

        let invitation = try #require(SearchKeyInvitation(for: error))

        #expect(invitation.actionTitle == "Ajouter une clé de recherche")
        #expect(invitation.explanation == SearchKeyInvitation.addKeyExplanation)
    }

    @Test("Une clé dans les échecs : on nomme le service, et on n'invite pas à « ajouter »", arguments: [
        (WebSearchSourceKind.braveSearch, "Brave Search"), (.tavily, "Tavily"),
    ])
    func oneKeyInTheFailures(kind: WebSearchSourceKind, name: String) throws {
        let error = WebSearchChainError.allSourcesFailed([failure(kind, .unauthorized), failure(.searxng)])

        let invitation = try #require(SearchKeyInvitation(for: error))

        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(invitation.explanation == "Ta clé \(name) n'a pas fonctionné.")
    }

    @Test("Les deux clés dans les échecs : au pluriel, dans l'ordre de préférence quel que soit celui des échecs")
    func bothKeysInTheFailures() throws {
        let error = WebSearchChainError.allSourcesFailed([failure(.tavily, .rateLimited), failure(.braveSearch, .unauthorized)])

        let invitation = try #require(SearchKeyInvitation(for: error))

        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(invitation.explanation == "Tes clés Brave Search et Tavily n'ont pas fonctionné.")
    }

    @Test("Clé illisible dans le trousseau : elle existe peut-être, on invite à vérifier, pas à ajouter")
    func unreadableKeyCountsAsAKey() throws {
        let error = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .braveSearch, reason: .keychainUnreadable),
            failure(.searxng),
        ])

        let invitation = try #require(SearchKeyInvitation(for: error))

        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(invitation.explanation == "Ta clé Brave Search n'a pas fonctionné.")
    }

    @Test("Une autre erreur ne se règle pas avec une clé de recherche : pas d'invitation", arguments: [
        FailoverError.allInstancesUnavailable as any Error,
        WebSearchError.unavailable,
        CancellationError(),
        ChatViewModelError.emptyResponse,
        CloudBYOKError.providerFailure(provider: "Claude", reason: .rateLimited),
    ])
    func otherErrorsDoNotInvite(error: any Error) {
        #expect(SearchKeyInvitation(for: error) == nil)
    }

    @Test("Appareil hors ligne : pas d'invitation, même avec une clé illisible ou un délai dépassé", arguments: [
        [failure(.searxng, .noConnection), failure(.wikipedia, .noConnection)],
        [failure(.searxng, .timeout), failure(.wikipedia, .noConnection), failure(.marginalia, .unavailable)],
        [WebSearchSourceFailure(source: .braveSearch, reason: .keychainUnreadable), failure(.searxng, .noConnection)],
    ])
    @MainActor
    func offlineNeverInvites(failures: [WebSearchSourceFailure]) {
        let error = WebSearchChainError.allSourcesFailed(failures)

        #expect(error.isDeviceOffline)
        #expect(SearchKeyInvitation(for: error) == nil)
        #expect(ChatViewModel.userFacingMessage(for: error) == "Pas de connexion à internet. Reconnecte-toi, puis réessaie.")
    }

    @Test("Une réponse HTTP prouve que le réseau marche : invitation maintenue malgré un .noConnection", arguments: [
        WebSearchError.unauthorized, .rateLimited, .invalidResponse,
    ])
    func anHTTPAnswerIsNotOffline(answer: WebSearchError) throws {
        let error = WebSearchChainError.allSourcesFailed([failure(.braveSearch, answer), failure(.searxng, .noConnection)])

        #expect(!error.isDeviceOffline)
        let invitation = try #require(SearchKeyInvitation(for: error))
        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
    }

    @Test("Aucune source n'a constaté de coupure : invitation maintenue, ce n'est pas la connexion", arguments: [
        [failure(.searxng, .unavailable)], [failure(.searxng, .timeout), failure(.wikipedia, .timeout)],
    ])
    func noOfflineFailureStillInvites(failures: [WebSearchSourceFailure]) {
        let error = WebSearchChainError.allSourcesFailed(failures)

        #expect(!error.isDeviceOffline)
        #expect(SearchKeyInvitation(for: error) != nil)
    }

    @Test("L'explication ne reprend jamais le constat du bandeau")
    func theExplanationDoesNotRepeatTheBanner() throws {
        let error = WebSearchChainError.allSourcesFailed([failure(.searxng)])

        let invitation = try #require(SearchKeyInvitation(for: error))

        #expect(!error.userFacingMessage.contains(invitation.explanation))
        #expect(!invitation.explanation.contains("réponse"))
    }
}

// MARK: - Ligne « Résultats : … » (logique pure)

@Suite("MessageBubblePresentation — d'où viennent les résultats")
struct ResultsOriginLabelTests {
    private func answer(kind: WebSearchSourceKind?, webSources: Int = 2) -> MessageBubblePresentation.AnswerSnapshot {
        MessageBubblePresentation.AnswerSnapshot(
            state: .completed,
            hasBody: true,
            sourceCount: webSources,
            webSourceCount: webSources,
            webSourceKind: kind
        )
    }

    @Test("SearXNG, le cas normal : rien à signaler")
    func searXNGShowsNothing() {
        #expect(MessageBubblePresentation.resultsOriginLabel(answer(kind: .searxng)) == nil)
    }

    @Test("Toute autre source est nommée", arguments: WebSearchSourceKind.allCases.filter { $0 != .searxng })
    func otherSourcesAreNamed(kind: WebSearchSourceKind) {
        #expect(MessageBubblePresentation.resultsOriginLabel(answer(kind: kind)) == "Résultats\u{00A0}: \(kind.displayName)")
    }

    @Test("Source inconnue (message relu, recherche sans web) : aucune supposition")
    func unknownSourceShowsNothing() {
        #expect(MessageBubblePresentation.resultsOriginLabel(answer(kind: nil)) == nil)
    }

    /// La chaîne rend la dernière source qui a répondu, même à vide (`WebSearchChain`) : le contrat de
    /// RI1b exige de ne l'annoncer que si elle a fourni quelque chose.
    @Test("Source qui a répondu à vide : rien à annoncer")
    func emptyAnswerShowsNothing() {
        #expect(MessageBubblePresentation.resultsOriginLabel(answer(kind: .wikipedia, webSources: 0)) == nil)
    }

    /// `webSourceCount` et non `sourceCount` : Wikipédia a répondu à vide, les sources affichées sont
    /// toutes des fichiers joints.
    @Test("Sources tirées des seuls fichiers joints : rien à annoncer")
    func attachmentsOnlyShowNothing() {
        let snapshot = MessageBubblePresentation.AnswerSnapshot(
            state: .completed,
            hasBody: true,
            sourceCount: 3,
            webSourceCount: 0,
            webSourceKind: .wikipedia
        )
        #expect(MessageBubblePresentation.resultsOriginLabel(snapshot) == nil)
    }
}

// MARK: - ChatViewModel de bout en bout

/// Provider IA factice : classification vide (repli sûr, recherche web générale), puis `answer` ou,
/// s'il y en a une, `answerError` au moment de rédiger.
private final class SearchFallbackAIProvider: AIGenerating {
    private let answerError: (any Error)?

    init(answerError: (any Error)? = nil) {
        self.answerError = answerError
    }

    func generate(prompt: String) async throws -> String {
        if prompt.contains("<user_query>") { return "" }
        if let answerError { throw answerError }
        return "Réponse factice."
    }
}

/// `WiringFixtures` de `WebSearchChainWiringTests` est privé.
@MainActor
private enum Fixtures {
    static let found = [ChainFixtures.result("Trouvé", url: "https://trouve.example/page")]

    /// `sources` : la chaîne ne contient qu'elles.
    static func chain(_ sources: Provider...) -> WebSearchChain {
        WebSearchChain(keyedProviders: sources, searxng: nil, openSourceProviders: { _ in [] })
    }

    /// Le `makeOrchestrator` PAR DÉFAUT : c'est le branchement réel qui est vérifié.
    static func makeViewModel(
        aiProvider: SearchFallbackAIProvider = SearchFallbackAIProvider(),
        historyStore: ChatHistoryStore? = nil,
        resolveChain: @escaping @MainActor (FailoverManager) throws -> WebSearchChain?
    ) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: resolveChain,
            readResponseMode: { .quick },
            historyStore: historyStore,
            generateSuggestions: { _, _ in [] }
        )
    }

    /// Enchaîne les chaînes données, une par envoi.
    static func makeSequencedResolver(_ chains: [WebSearchChain]) -> @MainActor (FailoverManager) -> WebSearchChain? {
        var remaining = chains
        return { _ in remaining.isEmpty ? nil : remaining.removeFirst() }
    }
}

@MainActor
@Suite("ChatViewModel — échec total de la recherche et source des résultats")
struct ChatViewModelSearchFallbackTests {
    private typealias F = Fixtures

    private let allFailing = Provider(kind: .searxng, outcome: .failure(WebSearchError.unavailable))

    // MARK: Invitation

    @Test("Toutes les sources en échec : bandeau au texte fixe, invitation, aucune recherche de plus")
    func allSourcesFailedInvites() async throws {
        let viewModel = F.makeViewModel(resolveChain: { [allFailing] _ in F.chain(allFailing) })

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .failed)
        #expect(viewModel.errorDescription == "Aucune source de recherche n'a répondu. Vérifie ta connexion, puis réessaie.")
        let invitation = try #require(viewModel.searchKeyInvitation)
        #expect(invitation.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("Hors ligne : bandeau sur la connexion, aucune invitation")
    func offlineShowsConnectionMessageWithoutInvitation() async throws {
        let offline = Provider(kind: .searxng, outcome: .failure(WebSearchError.noConnection))
        let viewModel = F.makeViewModel(resolveChain: { _ in F.chain(offline) })

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .failed)
        #expect(viewModel.errorDescription == "Pas de connexion à internet. Reconnecte-toi, puis réessaie.")
        #expect(viewModel.searchKeyInvitation == nil)
    }

    @Test("Clé personnelle en échec dans la chaîne : l'invitation propose de vérifier les clés")
    func aFailingKeyAsksToCheckIt() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.unauthorized))
        let viewModel = F.makeViewModel(resolveChain: { _ in F.chain(brave) })

        await viewModel.send(query: "q")

        let invitation = try #require(viewModel.searchKeyInvitation)
        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(invitation.explanation.contains("Brave Search"))
    }

    @Test("Une recherche réussie ne laisse aucune invitation")
    func aSuccessfulSearchHasNoInvitation() async {
        let viewModel = F.makeViewModel(resolveChain: { _ in
            F.chain(Provider(kind: .searxng, outcome: .results(F.found)))
        })

        await viewModel.send(query: "q")

        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    /// Décision D3 de RI1b, arbitrage réservé à Ben : la question n'a simplement aucun résultat.
    @Test("Toutes les sources ont répondu à VIDE : ce n'est pas un échec, pas d'invitation")
    func allEmptyAnswersDoNotInvite() async {
        let viewModel = F.makeViewModel(resolveChain: { _ in
            F.chain(Provider(kind: .wikipedia, outcome: .results([])))
        })

        await viewModel.send(query: "q")

        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    @Test("Un moteur IA en panne ne se règle pas avec une clé de recherche : bandeau, sans invitation")
    func anEngineFailureDoesNotInvite() async throws {
        let aiProvider = SearchFallbackAIProvider(answerError: ChatViewModelError.emptyResponse)
        let viewModel = F.makeViewModel(aiProvider: aiProvider, resolveChain: { _ in
            F.chain(Provider(kind: .searxng, outcome: .results(F.found)))
        })

        await viewModel.send(query: "q")

        #expect(viewModel.errorDescription != nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    @Test("L'envoi suivant efface l'invitation, même s'il réussit grâce à une clé ajoutée entre-temps")
    func theNextSendClearsTheInvitation() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let viewModel = F.makeViewModel(resolveChain: F.makeSequencedResolver([F.chain(allFailing), F.chain(brave)]))

        await viewModel.send(query: "première")
        #expect(viewModel.searchKeyInvitation != nil)

        await viewModel.send(query: "seconde")

        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
        #expect(viewModel.messages.last?.status == .completed)
        #expect(viewModel.messages.last?.webSourceKind == .braveSearch)
    }

    @Test("« Nouvelle conversation » efface le bandeau et l'invitation")
    func aNewConversationClearsTheInvitation() async {
        let viewModel = F.makeViewModel(resolveChain: { [allFailing] _ in F.chain(allFailing) })
        await viewModel.send(query: "q")
        #expect(viewModel.searchKeyInvitation != nil)

        viewModel.startNewConversation()

        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    @Test("Stop pendant la recherche : ni bandeau ni invitation")
    func cancellingDoesNotInvite() async throws {
        let waiting = Provider(kind: .searxng, outcome: .waitForCancellation)
        let viewModel = F.makeViewModel(resolveChain: { _ in F.chain(waiting) })

        let task = Task { await viewModel.send(query: "q") }
        await ChainFixtures.waitUntil("source interrogée") { await waiting.callCount == 1 }
        task.cancel()
        await task.value

        #expect(viewModel.messages.last?.status == .interrupted)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    /// Le jeton `activeExchangeID` protège `errorDescription` : l'invitation suit la même garde,
    /// sinon l'échec d'un échange abandonné s'afficherait sous la conversation suivante.
    @Test("Échec d'un échange abandonné : ni bandeau ni invitation dans la conversation suivante")
    func aStaleExchangeLeavesNoInvitation() async throws {
        let gate = StallingSource(kind: .searxng)
        let viewModel = F.makeViewModel(resolveChain: { _ in
            WebSearchChain(keyedProviders: [gate], searxng: nil, openSourceProviders: { _ in [] })
        })

        let abandoned = Task { await viewModel.send(query: "ancienne") }
        await ChainFixtures.waitUntil("source interrogée") { await gate.isWaiting }
        viewModel.startNewConversation()
        await gate.release()
        await abandoned.value

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.searchKeyInvitation == nil)
    }

    // MARK: Source des résultats

    @Test("La source de la chaîne arrive sur le message, avec ses sources", arguments: [
        WebSearchSourceKind.searxng, .braveSearch, .tavily, .cloudProviderWebSearch, .wikipedia, .openAlex, .arXiv, .marginalia,
    ])
    func theSourceReachesTheMessage(kind: WebSearchSourceKind) async throws {
        let viewModel = F.makeViewModel(resolveChain: { _ in F.chain(Provider(kind: kind, outcome: .results(F.found))) })

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.webSourceKind == kind)

        let snapshot = MessageBubbleView.answerSnapshot(of: answer)
        #expect(snapshot.webSourceKind == kind)
        let expected = kind == .searxng ? nil : "Résultats\u{00A0}: \(kind.displayName)"
        #expect(MessageBubblePresentation.resultsOriginLabel(snapshot) == expected)
    }

    @Test("Sans chaîne (défaut de l'init) : SearXNG, donc aucune ligne sous les sources")
    func withoutAChainNothingIsDisplayed() async throws {
        let manager = FailoverManager(client: ChainSearXNGClient(results: F.found), instances: [ChainFixtures.instance])
        let aiProvider = SearchFallbackAIProvider()
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.webSourceKind == .searxng)
        #expect(MessageBubblePresentation.resultsOriginLabel(MessageBubbleView.answerSnapshot(of: answer)) == nil)
    }

    /// « Persister ce libellé n'est PAS demandé » : un message relu n'annonce rien plutôt qu'une
    /// supposition, et ne perd pas pour autant ses sources.
    @Test("Conversation relue : les sources reviennent, le libellé non (non persisté)")
    func aRestoredMessageHasNoLabel() async throws {
        let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory())
        let first = F.makeViewModel(historyStore: store, resolveChain: { _ in
            F.chain(Provider(kind: .wikipedia, outcome: .results(F.found)))
        })
        await first.send(query: "q")
        #expect(first.messages.last?.webSourceKind == .wikipedia)
        let conversationID = try #require(first.currentConversationID)

        let second = F.makeViewModel(historyStore: store, resolveChain: { _ in nil })
        #expect(second.loadConversation(id: conversationID))

        let restored = try #require(second.messages.last)
        #expect(restored.sources.map(\.url) == F.found.map(\.url))
        #expect(restored.webSourceKind == nil)
        #expect(MessageBubblePresentation.resultsOriginLabel(MessageBubbleView.answerSnapshot(of: restored)) == nil)
    }

    // MARK: Messages typés des moteurs (B6), dans le bandeau

    /// Point 4 de la mission : le chemin réel, flux compris, jusqu'à `errorDescription`, seule source
    /// du bandeau de `ChatView`. Les textes eux-mêmes sont testés par `EngineErrorMessagesTests`.
    @Test("Une erreur typée levée pendant la rédaction atteint le bandeau avec son message propre", arguments: [
        (CloudBYOKError.providerFailure(provider: "Claude", reason: .rateLimited) as any Error,
         CloudProviderFailure.rateLimited.userFacingMessage(provider: "Claude")),
        (OpenAICompatibleProviderError.providerFailure(provider: "Groq", reason: .apiKeyRejected(statusCode: 401)) as any Error,
         CloudProviderFailure.apiKeyRejected(statusCode: 401).userFacingMessage(provider: "Groq")),
        (AppleIntelligenceGenerationError.contextWindowExceeded as any Error,
         AppleIntelligenceGenerationError.contextWindowExceeded.userFacingMessage),
    ])
    func typedEngineErrorsReachTheBanner(error: any Error, expected: String) async throws {
        let aiProvider = SearchFallbackAIProvider(answerError: error)
        let viewModel = F.makeViewModel(aiProvider: aiProvider, resolveChain: { _ in
            F.chain(Provider(kind: .searxng, outcome: .results(F.found)))
        })

        await viewModel.send(query: "q")

        #expect(viewModel.messages.last?.status == .failed)
        #expect(viewModel.errorDescription == expected)
        #expect(viewModel.searchKeyInvitation == nil)
    }
}

/// Source qui reste en suspens jusqu'à `release()` puis lève une erreur, SANS réagir à l'annulation :
/// c'est ce qui fait durer un échange abandonné au-delà de « Nouvelle conversation ».
private actor StallingSource {
    nonisolated let kind: WebSearchSourceKind
    private var continuation: CheckedContinuation<Void, Never>?

    init(kind: WebSearchSourceKind) {
        self.kind = kind
    }

    var isWaiting: Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    fileprivate func stall() async {
        await withCheckedContinuation { continuation = $0 }
    }
}

extension StallingSource: WebSearchProviding {
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        await stall()
        throw WebSearchError.unavailable
    }
}
