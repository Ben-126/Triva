//
//  SearchOrchestratorFollowUpTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Bug 1 (question de suivi) de `SearchOrchestratorStreamingTests`.

extension SearchOrchestratorStreamingTests {
    // MARK: - Bug 1 : une question de suivi garde son contexte

    /// JSON de classification valide pour `QueryClassifier.parse` : tous les
    /// booléens à `false` (donc `.webSearch`), sauf `skipSearch` si demandé.
    static func classificationJSON(skipSearch: Bool = false, standaloneFollowUp: String) -> String {
        #"{"classification":{"skipSearch":\#(skipSearch),"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"\#(standaloneFollowUp)"}"#
    }

    private static let appleHistory = [
        ClassifierChatMessage(role: .user, content: "Qui est le PDG d'Apple ?"),
        ClassifierChatMessage(role: .assistant, content: "Tim Cook dirige Apple depuis 2011[1]."),
    ]

    @Test("Bug 1 : un suivi interroge SearXNG et le planner avec la reformulation ; le prompt final garde la question d'origine, la reformulation et l'historique")
    func followUpSearchesWithStandaloneReformulation() async throws {
        let results = [Self.makeResult(title: "Salaire", url: "https://salaire.example", content: "Contenu salaire")]
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = StreamingMockAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "Salaire de Tim Cook, PDG d'Apple"))
        let orchestrator = makeStreamingOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.streamAnswer(query: "Et quel est son salaire ?", chatHistory: Self.appleHistory)

        // Avant le correctif, SearXNG recevait « Et quel est son salaire ? ».
        #expect(await client.receivedQueries == ["Salaire de Tim Cook, PDG d'Apple"])
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("Requête de l'utilisateur : Salaire de Tim Cook, PDG d'Apple"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Assistant : Tim Cook dirige Apple depuis 2011[1]."))
        #expect(finalPrompt.contains("Question reformulée d'après la conversation : Salaire de Tim Cook, PDG d'Apple\n"))
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : Et quel est son salaire ?"))
    }

    @Test("Bug 1 : reformulation blanche — la recherche repart de la question d'origine, sans ligne de reformulation")
    func blankReformulationFallsBackToOriginalQuery() async throws {
        let client = StreamingMockSearXNGClient()
        let aiProvider = StreamingMockAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "  "))
        let orchestrator = makeStreamingOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.streamAnswer(query: "Prix du cuivre aujourd'hui")

        #expect(await client.receivedQueries == ["Prix du cuivre aujourd'hui"])
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(!finalPrompt.contains("Question reformulée"))
    }

    @Test("effectiveQuery : reformulation nettoyée ; repli sur la question si elle est vide, blanche ou anormalement longue", arguments: [
        (standalone: "  Salaire de Tim Cook \n", expected: "Salaire de Tim Cook"),
        (standalone: "", expected: "Et son salaire ?"),
        (standalone: " \n\t", expected: "Et son salaire ?"),
        (standalone: String(repeating: "a", count: SearchOrchestrator.maxStandaloneQueryCharacters + 1), expected: "Et son salaire ?"),
    ])
    func effectiveQueryFallsBackOnUnusableReformulation(standalone: String, expected: String) {
        #expect(SearchOrchestrator.effectiveQuery(for: "Et son salaire ?", standaloneFollowUp: standalone) == expected)
    }

    @Test("effectiveQuery : une question déjà longue garde une reformulation de même longueur")
    func longQueryKeepsEquallyLongReformulation() {
        let reformulation = String(repeating: "r", count: 400)
        #expect(SearchOrchestrator.effectiveQuery(for: String(repeating: "q", count: 400), standaloneFollowUp: reformulation) == reformulation)
    }

    @Test("Bug 1 : chemin .skip (« Traduis ta réponse ») — prompt de conversation avec la réponse précédente, sans sources exigées ni phrase de refus")
    func skipPathAnswersFromConversation() async throws {
        let client = StreamingMockSearXNGClient()
        let classification = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Traduire en anglais la réponse sur Tim Cook")
        let aiProvider = StreamingMockAIGenerating(classifyResponse: classification)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            // Rapide, plus Fiable (mission E2a, décision de Ben du 2026-11-12) : « En Fiable, TOUJOURS
            // chercher, sauf salutation et calcul » ; une demande sur la conversation y cherche
            // désormais (`SearchRouteReliableModeTests`). Le chemin .skip reste celui des autres modes.
            responseMode: .quick
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "Traduis ta réponse en anglais", chatHistory: Self.appleHistory)

        #expect(streamingAnswer.sources.isEmpty)
        #expect(await client.receivedQueries.isEmpty)
        #expect(aiProvider.plannerPromptCount == 0)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Assistant : Tim Cook dirige Apple depuis 2011[1]."))
        #expect(finalPrompt.contains("Aucune recherche web n'a été lancée"))
        // Avant : le prompt exigeait « les sources numérotées » absentes, puis
        // imposait le refus ou, en Fiable, l'avertissement « aucune source ».
        #expect(!finalPrompt.contains("sources numérotées"))
        #expect(!finalPrompt.contains("<contexte>"))
        #expect(!finalPrompt.contains(PromptTemplates.noRelevantInformationAnswer))
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : Traduis ta réponse en anglais"))
    }

    @Test("E2a : en Fiable, le chemin sans recherche d'un calcul garde un prompt de conversation, sans sources exigées ni refus")
    func reliableCalculationPathKeepsTheConversationPrompt() async throws {
        let client = StreamingMockSearXNGClient()
        let classification = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "15 % de 240").replacingOccurrences(of: "\"showCalculationWidget\":false", with: "\"showCalculationWidget\":true")
        let aiProvider = StreamingMockAIGenerating(classifyResponse: classification)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable,
            // Le widget calcul RÉPOND : sans lui, Fiable cherche (mission C1, K2, test ci-dessous).
            widgets: [StubSearchWidget(kind: .calculation, llmContext: "Résultat : 36", log: WidgetCallLog())]
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "Combien font 15 % de 240 ?", chatHistory: Self.appleHistory)

        #expect(streamingAnswer.sources.isEmpty)
        #expect(await client.receivedQueries.isEmpty)
        #expect(aiProvider.plannerPromptCount == 0)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        // Le bloc des widgets dit lui-même « ce ne sont pas des sources numérotées » : on cible la consigne de rédaction.
        #expect(!finalPrompt.contains("en t'appuyant sur les sources numérotées"))
        #expect(!finalPrompt.contains("<contexte>"))
        #expect(!finalPrompt.contains(PromptTemplates.noRelevantInformationAnswer))
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : Combien font 15 % de 240 ?"))
    }

    @Test("C1 K2 : en Fiable, un calcul dont le widget ne produit rien cherche sur le web au lieu de répondre de mémoire")
    func reliableCalculationWithoutWidgetOutputSearches() async throws {
        let client = StreamingMockSearXNGClient()
        let classification = SearchOrchestratorTests.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "jours avant Noël")
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(classifyResponse: classification),
            responseMode: .reliable,
            widgets: [StubSearchWidget(kind: .calculation, llmContext: nil, log: WidgetCallLog())]
        )

        _ = try await orchestrator.streamAnswer(query: "Combien de jours avant Noël ?", chatHistory: Self.appleHistory)

        #expect(!(await client.receivedQueries.isEmpty))
    }

    @Test("Bug 1 : l'historique du prompt final est borné en nombre ET en longueur par message, selon les réglages de l'init")
    func finalPromptHistoryIsBoundedByInitSettings() async throws {
        let history = [
            ClassifierChatMessage(role: .user, content: "Premier sujet abandonné"),
            ClassifierChatMessage(role: .assistant, content: "Réponse au premier sujet."),
            ClassifierChatMessage(role: .user, content: "Parle-moi de la photosynthèse"),
            ClassifierChatMessage(role: .assistant, content: String(repeating: "La photosynthèse produit du glucose. ", count: 100)),
        ]
        let aiProvider = StreamingMockAIGenerating()
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: StreamingMockSearXNGClient(), instances: [Self.instance]),
            aiProvider: aiProvider,
            maxHistoryMessages: 2,
            maxHistoryMessageCharacters: 80
        )

        _ = try await orchestrator.streamAnswer(query: "Et le rendement ?", chatHistory: history)

        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(!finalPrompt.contains("Premier sujet abandonné"))
        #expect(finalPrompt.contains("Utilisateur : Parle-moi de la photosynthèse"))
        // 80 caractères : coupe à la dernière fin de phrase (74), marquée « […] ».
        #expect(finalPrompt.contains("Assistant : La photosynthèse produit du glucose. La photosynthèse produit du glucose. […]"))
        #expect(finalPrompt.components(separatedBy: "produit du glucose").count == 3)
    }
}
