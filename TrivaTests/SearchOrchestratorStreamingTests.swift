//
//  SearchOrchestratorStreamingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockError: Error, Sendable, Equatable {
    case searchFailed
    case midStreamFailure
}

/// Même principe que `MockSearXNGClient` de `SearchOrchestratorTests.swift`,
/// dupliqué ici (`private` est scopé au fichier) : renvoie une réponse fixe,
/// ou lève une erreur si configuré pour échouer.
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

/// Provider IA factice qui streame une suite de morceaux de texte fixe, avec
/// une erreur optionnelle en fin de flux (pour simuler un échec survenant
/// PENDANT le streaming, après un ou plusieurs yields).
///
/// Depuis 1.2, `SearchOrchestrator` appelle `generate(prompt:)` pour la
/// classification ET pour chaque tour planner (JAMAIS pour la génération
/// finale, qui passe exclusivement par `streamGenerate(prompt:)`) : les deux
/// méthodes enregistrent donc leurs prompts dans des tableaux SÉPARÉS —
/// mélanger les deux dans un seul tableau rendrait `receivedPrompts.first`
/// ambigu (tantôt le prompt de classification, tantôt celui du planner,
/// selon le chemin emprunté) là où seul `receivedStreamPrompts` représente
/// sans ambiguïté LE prompt de génération finale envoyé au flux. Les chunks
/// fixes ne sont jamais du JSON valide : classification et planner retombent
/// systématiquement sur leur repli sûr respectif (`.webSearch` / "done"),
/// donc le comportement observable du pipeline reste inchangé par ce
/// branchement — seul le suivi des prompts est plus précis qu'avant 1.2.
private final class MockStreamingAIGenerating: AIGenerating {
    private(set) var receivedGeneratePrompts: [String] = []
    private(set) var receivedStreamPrompts: [String] = []
    private let chunks: [String]
    private let midStreamFailure: (any Error)?

    init(chunks: [String] = ["chunk"], midStreamFailure: (any Error)? = nil) {
        self.chunks = chunks
        self.midStreamFailure = midStreamFailure
    }

    func generate(prompt: String) async throws -> String {
        receivedGeneratePrompts.append(prompt)
        return chunks.joined()
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        receivedStreamPrompts.append(prompt)
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let midStreamFailure {
                continuation.finish(throwing: midStreamFailure)
            } else {
                continuation.finish()
            }
        }
    }
}

@Suite("SearchOrchestrator.streamAnswer")
struct SearchOrchestratorStreamingTests {
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

    @Test("Cas nominal : les sources sont renvoyées immédiatement, le flux produit les morceaux du provider dans l'ordre")
    func happyPathReturnsSourcesAndStreamsChunks() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Voici ", "la ", "réponse."])
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "quelle est la question ?")

        #expect(streamingAnswer.sources == results)

        var received: [String] = []
        for try await chunk in streamingAnswer.textStream {
            received.append(chunk)
        }
        #expect(received == ["Voici ", "la ", "réponse."])

        // Un seul appel à `streamGenerate` : la génération finale, jamais la
        // classification ni le planner (qui passent par `generate`).
        let streamPrompts = await aiProvider.receivedStreamPrompts
        #expect(streamPrompts.count == 1)
        let prompt = try #require(streamPrompts.first)
        #expect(prompt.contains("quelle est la question ?"))
        #expect(prompt.contains("Titre A"))
        #expect(prompt.contains("Titre B"))
    }

    @Test("La limite maxResultsUsedForContext restreint les sources renvoyées, comme answer(query:)")
    func maxResultsLimitsReturnedSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(streamingAnswer.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])
    }

    @Test("Une erreur de recherche remonte AVANT que le flux final soit sollicité : streamAnswer() lève, streamGenerate() n'est jamais appelé (seule la classification, via generate(), a eu lieu)")
    func searchErrorPropagatesBeforeCallingAIProvider() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.streamAnswer(query: "requête")
        }

        let generatePrompts = await aiProvider.receivedGeneratePrompts
        let streamPrompts = await aiProvider.receivedStreamPrompts
        #expect(generatePrompts.count == 1)
        #expect(streamPrompts.isEmpty)
    }

    @Test("Une erreur survenant DANS le stream du provider IA (après des yields) est propagée par le flux, pas par streamAnswer() elle-même")
    func errorInsideProviderStreamPropagatesThroughTextStream() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["premier morceau"], midStreamFailure: MockError.midStreamFailure)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        // streamAnswer() elle-même ne lève pas : la recherche a réussi, seul le
        // flux de texte (consommé séparément ci-dessous) porte l'échec.
        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        var received: [String] = []
        await #expect(throws: MockError.midStreamFailure) {
            for try await chunk in streamingAnswer.textStream {
                received.append(chunk)
            }
        }
        #expect(received == ["premier morceau"])
    }
}
