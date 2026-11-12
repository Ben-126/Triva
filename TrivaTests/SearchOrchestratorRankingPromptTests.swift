//
//  SearchOrchestratorRankingPromptTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Classement (1.3) et prompt de rédaction (1.4) de `SearchOrchestratorTests`.

extension SearchOrchestratorTests {
    // MARK: - Classement (1.3) et prompt de rédaction (1.4)

    @Test("Le classement remplace le simple prefix : la source la mieux notée passe en tête, et son rang devient son numéro de citation")
    func rankingReordersSourcesAndCitationNumbers() async throws {
        let results = (1...4).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = PipelineMockAIGenerating()
        let ranker = SourceRanker(
            relevanceScorer: PipelineFixedSimilarityScorer(scoresByText: ["Contenu 3": 0.95], defaultScore: 0.3),
            duplicateScorer: PipelineNeverDuplicateScorer(),
            languageIdentifier: PipelinePrefixLanguageIdentifier()
        )
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            sourceRanker: ranker
        )

        let result = try await orchestrator.answer(query: "requête")

        // (0,95*0,7 + 0,8*0,3) = 0,905 pour le 3e, contre 0,51 au mieux pour
        // les autres : il passe devant, les autres gardent l'ordre du moteur.
        #expect(result.sources.map(\.title) == ["Titre 3", "Titre 1", "Titre 2", "Titre 4"])
        // Invariant des citations : `[n]` du prompt == `sources[n - 1]`.
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] Titre 3 — https://3.example"))
        #expect(finalPrompt.contains("[2] Titre 1 — https://1.example"))
    }

    @Test("Décision 3 dans le pipeline : chaque langue est classée à part puis les meilleures sont alternées")
    func pipelineInterleavesLanguages() async throws {
        let french = (1...4).map { Self.makeResult(title: "Article \($0)", url: "https://fr\($0).example", content: "FR contenu \($0)") }
        let english = Self.makeResult(title: "Article EN", url: "https://en.example", content: "EN content")
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: french + [english], suggestions: []))
        // Le biais mesuré : la langue de la requête marque plus haut que le
        // sens. Classé d'un bloc, l'extrait anglais finirait dernier.
        let scores = ["FR contenu 1": 0.9, "FR contenu 2": 0.9, "FR contenu 3": 0.9, "FR contenu 4": 0.9, "EN content": 0.5]
        let ranker = SourceRanker(
            relevanceScorer: PipelineFixedSimilarityScorer(scoresByText: scores, defaultScore: 0),
            duplicateScorer: PipelineNeverDuplicateScorer(),
            languageIdentifier: PipelinePrefixLanguageIdentifier()
        )
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: PipelineMockAIGenerating(),
            responseMode: .quick,
            sourceRanker: ranker
        )

        let result = try await orchestrator.answer(query: "FR question en français")

        #expect(result.sources.map(\.url) == ["https://fr1.example", "https://en.example", "https://fr2.example"])
    }

    @Test("Le prompt final est le prompt de rédaction : citations [n], consignes du mode, contexte numéroté")
    func finalPromptIsTheWriterPrompt() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "question")

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("### Citations"))
        #expect(finalPrompt.contains("mode Approfondi"))
        #expect(finalPrompt.contains("[1] Titre A — https://a.example\nExtrait : Contenu A"))
        // Une formulation bannie est listée dans les consignes (interpolée
        // depuis la source de vérité unique de `PromptTemplates`).
        let bannedPhrase = try #require(PromptTemplates.bannedFillerPhrases.first)
        #expect(finalPrompt.contains(bannedPhrase))
    }

    @Test("writerComplexity .concise : le prompt court destiné aux petits modèles est utilisé")
    func conciseWriterComplexityIsForwarded() async throws {
        let client = PipelineMockSearXNGClient()
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            writerComplexity: .concise
        )

        _ = try await orchestrator.answer(query: "question")

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasPrefix("Tu es Triva. Réponds à la question en t'appuyant uniquement sur les sources numérotées"))
        #expect(!finalPrompt.contains("### Principes fondamentaux"))
    }

    @Test("L'historique de conversation est transmis au prompt de rédaction")
    func chatHistoryReachesWriterPrompt() async throws {
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: PipelineMockSearXNGClient(), instances: [Self.instance]), aiProvider: aiProvider)
        let history = [
            ClassifierChatMessage(role: .user, content: "Qui dirige Apple ?"),
            ClassifierChatMessage(role: .assistant, content: "Tim Cook[1]."),
        ]

        _ = try await orchestrator.answer(query: "Et son salaire ?", chatHistory: history)

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Utilisateur : Qui dirige Apple ?"))
        #expect(finalPrompt.contains("Assistant : Tim Cook[1]."))
    }

    @Test("Protection anti-overflow niveau 2 conservée : le budget de contenu scrapé est partagé entre les documents")
    func scrapedContextBudgetIsSharedAcrossDocuments() async throws {
        // Deux sources AFFICHÉES : depuis le bug 8, une URL hors des sources
        // n'est plus scrapée, et le budget ne serait plus partagé du tout.
        let results = ["a", "b"].map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example"],"reasoning":"approfondir"}
        """
        let aiProvider = PipelineMockAIGenerating(plannerResponses: [scrapeJSON])
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            maxScrapedContextCharacters: 20
        )

        _ = try await orchestrator.answer(query: "question")

        // 2 documents portent du contenu scrapé -> 10 caractères chacun
        // (« Contenu sc ») ; un seul document en aurait reçu 20.
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu de la page : Contenu sc"))
        #expect(!finalPrompt.contains("Contenu de la page : Contenu scr"))
        #expect(!finalPrompt.contains("Contenu scrapé pour https://a.example"))
        #expect(!finalPrompt.contains("Contenu scrapé pour https://b.example"))
    }

    @Test("effectiveLimit : le plus petit du plafond et de la valeur du mode, jamais négatif", arguments: [
        (cap: 5, modeValue: 3, expected: 3),
        (cap: 2, modeValue: 5, expected: 2),
        (cap: 5, modeValue: 5, expected: 5),
        (cap: 0, modeValue: 5, expected: 0),
        (cap: -1, modeValue: 5, expected: 0),
    ])
    func effectiveLimitIsTheSmallerBound(cap: Int, modeValue: Int, expected: Int) {
        #expect(SearchOrchestrator.effectiveLimit(cap: cap, modeValue: modeValue) == expected)
    }
}
