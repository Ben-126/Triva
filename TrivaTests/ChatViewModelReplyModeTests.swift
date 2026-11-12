//
//  ChatViewModelReplyModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    // MARK: - Historique passé au classifieur et au prompt final (bug 1)

    @Test("Le classifieur ET le prompt final reçoivent les tours précédents, jamais le message courant (bug 1)")
    func chatHistoryPassedToClassifierExcludesCurrentTurn() async throws {
        let aiProvider = MockStreamingAIGenerating(chunks: ["réponse fixe"])
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "premier message")
        await viewModel.send(query: "second message")

        // Classifieur : le 2e prompt porte le 1er tour, sans le message courant
        // (qui est dans <user_query>, hors du bloc).
        #expect(aiProvider.classifierPrompts.count == 2)
        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        #expect(classifierHistory.contains("premier message"))
        #expect(classifierHistory.contains("réponse fixe"))
        #expect(!classifierHistory.contains("second message"))

        // Prompt FINAL (ce que le prompt de revue demandait en plus) :
        // l'historique borné y est, la question courante n'est posée qu'une fois.
        #expect(aiProvider.receivedStreamPrompts.count == 2)
        #expect(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.first) == "Aucun échange précédent.")
        let finalHistory = try #require(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.last))
        #expect(finalHistory.contains("Utilisateur : premier message"))
        #expect(finalHistory.contains("Assistant : réponse fixe"))
        #expect(!finalHistory.contains("second message"))
        #expect(aiProvider.receivedStreamPrompts.last?.contains("second message") == true)
    }

    @Test("Seuls les tours ABOUTIS entrent dans l'historique, par leur texte visible (sans <think>, TL;DR seul s'il n'y a pas de corps)")
    func historyKeepsOnlyCompletedTurns() {
        typealias Message = ChatViewModel.Message
        func answer(_ text: String, _ status: Message.Status) -> Message {
            var message = Message(role: .assistant, isStreaming: true)
            message.apply(snapshot: text, at: .now)
            message.finish(status, at: .now)
            return message
        }
        let messages = [
            Message(role: .user, text: "Q1"), answer("<think>caché</think>R1", .completed),
            Message(role: .user, text: "Q2"), answer("partiel", .failed),
            Message(role: .user, text: "Q3"), answer("coupé", .interrupted),
            Message(role: .user, text: "Q4"), answer("", .noReliableSources),
            Message(role: .user, text: "Q5"), answer("<tldr>Résumé seul</tldr>", .completed),
            Message(role: .user, text: "Q6"), Message(role: .assistant, isStreaming: true),
        ]

        let history = ChatViewModel.classifierHistory(from: messages)

        #expect(history.map(\.content) == ["Q1", "R1", "Q5", "Résumé seul"])
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("Le raisonnement est segmenté pendant le flux et reste HORS des prompts suivants ; le texte brut est conservé (1.14)")
    func reasoningIsSegmentedAndKeptOutOfTheNextPrompts() async throws {
        let aiProvider = MockStreamingAIGenerating(chunks: [
            "<think>Je pèse le sujet secret",
            "<think>Je pèse le sujet secret</think>Réponse visible.",
        ])
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "Première question")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.text.hasPrefix("<think>"))
        #expect(answer.segments.body == "Réponse visible.")
        #expect(answer.segments.reasoning.contains("sujet secret"))
        #expect(answer.segments.reasoningPhase == .completed)
        #expect(answer.reasoningTiming.startedAt != nil)
        #expect(answer.reasoningTiming.endedAt != nil)

        await viewModel.send(query: "Seconde question")

        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        let finalHistory = try #require(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.last))
        #expect(classifierHistory.contains("Réponse visible."))
        #expect(finalHistory.contains("Réponse visible."))
        #expect(!classifierHistory.contains("sujet secret"))
        #expect(!finalHistory.contains("sujet secret"))
    }

    // MARK: - Mode de réponse et budget du moteur (1.13, bug 6)

    @Test("Le mode mémorisé et le budget du moteur sont relus à CHAQUE envoi et transmis au pipeline")
    func modeAndBudgetAreReadAtEachSend() async {
        let settings = SendSettings()
        settings.configuration = .appleIntelligence
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, settings: settings, factory: factory)

        await viewModel.send(query: "premier")
        settings.mode = .deep
        settings.configuration = .mlxCompact
        await viewModel.send(query: "second")

        #expect(factory.modes == [.quick, .deep])
        #expect(factory.configurations == [.appleIntelligence, .mlxCompact])
    }

    @Test("Sans injection : budget le plus serré (.appleIntelligence), conversation vierge, rien de persisté")
    func defaultsAreSafe() async throws {
        let factory = OrchestratorFactoryRecorder()
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager },
            readResponseMode: { .quick },
            makeOrchestrator: { inputs in
                factory.record(inputs)
                return Self.deterministicOrchestrator(inputs)
            },
            generateSuggestions: { _, _ in [] }
        )
        // Décision 1 de Ben : au lancement, conversation vierge.
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)
        #expect(viewModel.attachmentController.attachments.isEmpty)

        await viewModel.send(query: "Bonjour")

        #expect(factory.configurations == [.appleIntelligence])
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.storedMessageID == nil)
        #expect(viewModel.currentConversationID == nil)
        #expect(!viewModel.canToggleFavorite(answer))
        #expect(!viewModel.loadConversation(id: UUID()))
    }

    @Test("Mode mémorisé : Rapide par défaut, puis celui que le sélecteur a écrit (décision 6)")
    func persistedModeDefaultsToQuickThenFollowsTheSelector() throws {
        let suiteName = "ChatViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ChatViewModel.persistedResponseMode(in: defaults) == .quick)
        ResponseModeSettingsStore(userDefaults: defaults).selectedMode = .reliable
        #expect(ChatViewModel.persistedResponseMode(in: defaults) == .reliable)
    }

    // MARK: - Mode Fiable sans source fiable (décision (c))

    @Test("Mode Fiable, toutes les sources filtrées : état .noReliableSources, aucune génération, aucune erreur, état persisté")
    func reliableModeWithoutTrustedSourceShowsTheFixedState() async throws {
        let stores = try PersistenceStores()
        let settings = SendSettings()
        settings.mode = .reliable
        let suggestions = SuggestionsRecorder(result: ["Suggestion"])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse sans source."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            stores: stores,
            suggestions: suggestions
        )

        await viewModel.send(query: "Que pensent les gens de ce film ?")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .noReliableSources)
        #expect(answer.text.isEmpty)
        #expect(answer.sources.isEmpty)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.canRetryInQuickMode(answer))
        #expect(ChatViewModel.noReliableSourcesMessage == "Aucune source fiable pour ce type de question.")
        try? await Task.sleep(for: .milliseconds(10))
        #expect(suggestions.histories.isEmpty)
        // Aucune requête au moteur (l'orchestrateur ne génère pas).
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        // Décision de Ben (2026-10-30) : l'état est persisté après la question.
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(conversation.orderedMessages.last?.reportsNoReliableSources == true)
        #expect(answer.storedMessageID == conversation.orderedMessages.last?.id)
        #expect(!viewModel.canToggleFavorite(answer))
    }

    @Test("Une conversation relue montre l'état « Aucune source fiable » et propose encore la relance")
    func reloadedNoReliableSourcesStateIsShownWithItsRetry() async throws {
        let stores = try PersistenceStores()
        let conversation = try stores.history.createConversation(firstQuestion: "Que pensent les gens de ce film ?")
        try stores.history.appendUserMessage(to: conversation, text: "Que pensent les gens de ce film ?")
        let stored = try stores.history.appendNoReliableSourcesMessage(
            to: conversation, text: ChatViewModel.noReliableSourcesMessage
        )
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: ["x"]) }, stores: stores)

        #expect(viewModel.loadConversation(id: conversation.id))

        let restored = try #require(viewModel.messages.last)
        #expect(restored.status == .noReliableSources)
        #expect(restored.text.isEmpty)
        #expect(restored.storedMessageID == stored.id)
        #expect(viewModel.canRetryInQuickMode(restored))
        #expect(!viewModel.canToggleFavorite(restored))
        // Jamais dans l'historique du classifieur.
        #expect(ChatViewModel.classifierHistory(from: viewModel.messages).isEmpty)
    }

    @Test("« Relancer en mode Rapide » répond à la MÊME question en Rapide, sans la réécrire ni changer le mode mémorisé")
    func retryInQuickModeAnswersTheSameQuestion() async throws {
        let stores = try PersistenceStores()
        let settings = SendSettings()
        settings.mode = .reliable
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse rapide[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            stores: stores,
            factory: factory
        )
        await viewModel.send(query: "Que pensent les gens de ce film ?")
        let answerID = try #require(viewModel.messages.last?.id)

        await viewModel.retryInQuickMode(messageID: answerID)

        #expect(factory.modes == [.reliable, .quick])
        #expect(settings.mode == .reliable)
        #expect(viewModel.messages.count == 2)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.id == answerID)
        #expect(answer.status == .completed)
        #expect(answer.text == "Réponse rapide[1].")
        #expect(answer.sources == Self.untrustedResults)
        #expect(aiProvider.receivedStreamPrompts.last?.contains("Que pensent les gens de ce film ?") == true)
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.text) == ["Que pensent les gens de ce film ?", "Réponse rapide[1]."])
    }

    @Test("La relance n'est proposée que sur la DERNIÈRE réponse (sinon elle serait persistée hors ordre)")
    func retryIsOnlyOfferedOnTheLastAnswer() async throws {
        let settings = SendSettings()
        settings.mode = .reliable
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            factory: factory
        )
        await viewModel.send(query: "Question discussion")
        settings.mode = .quick
        await viewModel.send(query: "Question suivante")

        let olderAnswer = viewModel.messages[1]
        #expect(olderAnswer.status == .noReliableSources)
        #expect(!viewModel.canRetryInQuickMode(olderAnswer))
        #expect(!viewModel.canRetryInQuickMode(viewModel.messages[3]))

        await viewModel.retryInQuickMode(messageID: olderAnswer.id)

        #expect(viewModel.messages[1].status == .noReliableSources)
        #expect(factory.modes == [.reliable, .quick])
    }

    @Test("L'état sans source fiable exige le mode Fiable, une vraie recherche, et rien à montrer (ni source ni widget)")
    func lacksReliableSourcesRequiresAnEmptyReliableSearch() {
        func artifacts(
            mode: ResponseMode = .reliable,
            searched: Bool = true,
            sources: [SearXNGSearchResult] = [],
            widgets: [SearchWidgetOutput] = []
        ) -> SearchArtifacts {
            SearchArtifacts(
                sources: sources, attachmentSourceCount: 0, widgets: widgets,
                images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
                citableSourceCount: sources.count, searchPerformed: searched, searchQuery: "q"
            )
        }
        #expect(ChatViewModel.lacksReliableSources(artifacts()))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(mode: .quick)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(mode: .deep)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(searched: false)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(sources: Self.untrustedResults)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(widgets: [SearchWidgetOutput(kind: .calculation, llmContext: "84")])))
    }

}
