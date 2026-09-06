//
//  SearchOrchestratorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 06/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockError: Error, Sendable, Equatable {
    case searchFailed
    case generationFailed
}

/// Client SearXNG factice, même principe que `MockSearXNGClient` dans
/// FailoverManagerTests.swift : renvoie une réponse fixe, ou lève une erreur
/// si configuré pour échouer — sans le moindre appel réseau réel.
private actor MockSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        if shouldFail {
            throw MockError.searchFailed
        }
        return response
    }
}

/// Provider IA factice qui capture le prompt exact reçu, pour vérifier
/// précisément le contexte construit par `SearchOrchestrator`. Classe simple
/// plutôt qu'un acteur personnalisé, comme `AppleIntelligenceProvider`/
/// `CloudBYOKProvider` : `AIGenerating` hérite de l'isolation par défaut du
/// projet (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), et un acteur
/// personnalisé défini dans la cible de test ne peut pas satisfaire une
/// conformance à un protocole isolé sur un acteur global différent du sien —
/// laisser l'inférence par défaut s'appliquer (comme pour les autres
/// providers du projet) évite le problème.
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let response: String
    private let shouldFail: Bool

    init(response: String = "réponse factice", shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        if shouldFail {
            throw MockError.generationFailed
        }
        return response
    }
}

@Suite("SearchOrchestrator")
struct SearchOrchestratorTests {
    private static func makeResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    private static let instance = URL(string: "https://searxng.example")!

    @Test("Cas nominal : réponse et sources correspondent au mock, le prompt contient la requête et le contexte")
    func happyPath() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(response: "voici la réponse")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "quelle est la question ?")

        #expect(result.answer == "voici la réponse")
        #expect(result.sources == results)

        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.contains("quelle est la question ?"))
        #expect(prompt.contains("Titre A"))
        #expect(prompt.contains("Contenu A"))
        #expect(prompt.contains("Titre B"))
        #expect(prompt.contains("Contenu B"))
    }

    @Test("La limite par défaut (5) restreint le contexte et les sources retournées")
    func defaultMaxResultsLimitsContextAndSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 5)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])

        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(!prompt.contains("Titre 6"))
        #expect(!prompt.contains("Titre 7"))
    }

    @Test("Une limite personnalisée est honorée")
    func customMaxResultsIsHonored() async throws {
        let results = (1...4).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 2)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 2)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2"])
    }

    @Test("Zéro résultat de recherche : le provider IA est quand même appelé, sans crash")
    func zeroSearchResultsStillCallsAIProvider() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(response: "réponse sans contexte")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.answer == "réponse sans contexte")
        #expect(result.sources.isEmpty)
        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(prompt.contains("requête sans résultat"))
    }

    @Test("Un résultat sans contenu (nil) est géré sans crash")
    func resultWithoutContentDoesNotCrash() async throws {
        let results = [Self.makeResult(title: "Titre sans contenu", url: "https://sans-contenu.example", content: nil)]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources == results)
        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(prompt.contains("Titre sans contenu"))
    }

    @Test("Une erreur de FailoverManager remonte inchangée, le provider IA n'est pas appelé")
    func failoverErrorPropagatesWithoutCallingAIProvider() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.answer(query: "requête")
        }

        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.isEmpty)
    }

    @Test("Une erreur du provider IA remonte inchangée")
    func aiProviderErrorPropagates() async {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(shouldFail: true)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: MockError.generationFailed) {
            _ = try await orchestrator.answer(query: "requête")
        }
    }

    @Test("Une requête vide est transmise telle quelle (pas de validation à ce niveau) : le pipeline va quand même jusqu'au provider IA")
    func emptyQueryIsPassedThroughUnchanged() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(response: "réponse malgré requête vide")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "")

        #expect(result.answer == "réponse malgré requête vide")
        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(prompt.hasSuffix("Question : "))
    }

    @Test("Une requête composée uniquement d'espaces est transmise telle quelle, sans normalisation")
    func whitespaceOnlyQueryIsPassedThroughUnchanged() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(response: "réponse malgré requête blanche")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "   ")

        #expect(result.answer == "réponse malgré requête blanche")
        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(prompt.hasSuffix("Question : " + "   "))
    }

    @Test("maxResultsUsedForContext = 0 produit un contexte et des sources vides, sans crash")
    func zeroMaxResultsUsedForContextProducesEmptyContext() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(response: "réponse sans contexte")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 0)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.isEmpty)
        let prompt = try #require(await aiProvider.receivedPrompts.first)
        #expect(!prompt.contains("Titre A"))
    }
}
