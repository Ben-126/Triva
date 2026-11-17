//
//  ReadPageRegenerationTests.swift
//  TrivaTests
//
//  Mission C5 : « Lire cette page » refait la réponse en cours (décision de Ben, 2026-11-17).
//

import Testing
import Foundation
@testable import Triva

/// Scrape qui se comporte comme `ScrapeService` pour ce qui compte ici : une page lue à la demande
/// de l'utilisateur (`UserReadPages`) est servie avant tout réseau ; sinon, rien n'est lisible.
private struct UserReadAwareScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        UserReadPages.page(for: url) ?? ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

/// Une réponse de recherche par appel, la dernière répétée ensuite.
private actor SequencedSearXNGClient: SearXNGSearching {
    private var responses: [[SearXNGSearchResult]]

    init(responses: [[SearXNGSearchResult]]) { self.responses = responses }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        let results = responses.count > 1 ? responses.removeFirst() : (responses.first ?? [])
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

@MainActor
@Suite(.serialized)
struct ReadPageRegenerationTests {
    private static let instance = URL(string: "https://searxng.example")!
    private static let refusedURL = "https://refuse.example/article"
    private static let results = [
        SearXNGSearchResult(
            title: "Article refusé", url: refusedURL, content: "Simple extrait du moteur",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
        SearXNGSearchResult(
            title: "Autre source", url: "https://autre.example/page", content: "Autre extrait",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
    ]

    private func makeViewModel(
        provider: any AIGenerating,
        client: (any SearXNGSearching)? = nil,
        mode: ResponseMode = .deep,
        consentCalls: ConsentCounter = ConsentCounter()
    ) -> ChatViewModel {
        let failover = FailoverManager(
            client: client ?? ChatViewModelTests.MockSearXNGClient(
                response: SearXNGSearchResponse(results: Self.results, suggestions: [])
            ),
            instances: [Self.instance]
        )
        return ChatViewModel(
            resolveProvider: { provider },
            resolveFailoverManager: { failover },
            resolvePipelineConfiguration: { .cloud },
            readResponseMode: { mode },
            makeOrchestrator: { inputs in
                SearchOrchestrator(
                    failoverManager: inputs.failoverManager,
                    aiProvider: inputs.provider,
                    responseMode: inputs.responseMode,
                    configuration: inputs.configuration,
                    scrapeService: UserReadAwareScrapeService(),
                    sourceRanker: ChatViewModelTests.orderPreservingRanker(),
                    widgets: []
                )
            },
            generateSuggestions: { _, _ in [] },
            resolveConsentRequest: { consentCalls.count += 1; return nil }
        )
    }

    @MainActor
    final class ConsentCounter { var count = 0 }

    private func readPage(_ content: String = "CONTENU INTEGRAL DE LA PAGE LUE") -> ScrapedPage {
        ScrapedPage(url: Self.refusedURL, title: "Article refusé", content: content, succeeded: true)
    }

    @Test("Lecture réussie : la page lue est annoncée prête à refaire la réponse, rien n'est lancé tout seul")
    func successfulReadOffersRegeneration() async throws {
        UserReadPages.removeAll()
        defer { UserReadPages.removeAll() }
        let provider = ChatViewModelTests.MockStreamingAIGenerating(chunks: ["Réponse initiale."])
        let viewModel = makeViewModel(provider: provider)
        await viewModel.send(query: "Que dit l'article ?")
        let streamsBefore = provider.receivedStreamPrompts.count

        let outcome = await viewModel.readPage(url: Self.refusedURL) { _ in true }

        #expect(outcome == .readyToRegenerate)
        #expect(provider.receivedStreamPrompts.count == streamsBefore)
        #expect(viewModel.messages.last?.text == "Réponse initiale.")
    }

    @Test("Lecture échouée : aucune régénération possible, la réponse reste intacte")
    func failedReadNeverRegenerates() async throws {
        let provider = ChatViewModelTests.MockStreamingAIGenerating(chunks: ["Réponse initiale."])
        let viewModel = makeViewModel(provider: provider)
        await viewModel.send(query: "Que dit l'article ?")
        let streamsBefore = provider.receivedStreamPrompts.count

        let outcome = await viewModel.readPage(url: Self.refusedURL) { _ in false }

        #expect(outcome == .failed)
        #expect(provider.receivedStreamPrompts.count == streamsBefore)
        #expect(viewModel.messages.last?.text == "Réponse initiale.")
    }

    @Test("La réponse refaite reçoit le TEXTE de la page lue, à la place de l'extrait, avec les autres sources")
    func regeneratedAnswerContainsTheReadPage() async throws {
        UserReadPages.removeAll()
        defer { UserReadPages.removeAll() }
        let provider = ChatViewModelTests.MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(provider: provider)
        await viewModel.send(query: "Que dit l'article ?")
        let firstAnswerID = try #require(viewModel.messages.last?.id)
        #expect(provider.receivedStreamPrompts.last?.contains("CONTENU INTEGRAL DE LA PAGE LUE") == false)

        UserReadPages.store(readPage())
        await viewModel.regenerateLastAnswerWithReadPages()

        let finalPrompt = try #require(provider.receivedStreamPrompts.last)
        #expect(provider.receivedStreamPrompts.count == 2)
        #expect(finalPrompt.contains("CONTENU INTEGRAL DE LA PAGE LUE"), "page absente : \(finalPrompt)")
        #expect(finalPrompt.contains("Que dit l'article ?"))
        #expect(finalPrompt.contains("Autre extrait"), "autre extrait absent : \(finalPrompt)")
        // Même bulle, même question, jamais réécrite dans le fil.
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.last?.id == firstAnswerID)
        #expect(viewModel.messages.first?.text == "Que dit l'article ?")
        #expect(viewModel.messages.last?.status == .completed)
    }

    @Test("Une réponse plus ancienne que la dernière : page gardée, mais rien n'est refait (ordre du fil)")
    func olderAnswerIsNotRegenerated() async throws {
        let provider = ChatViewModelTests.MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(provider: provider, client: SequencedSearXNGClient(responses: [Self.results, [Self.results[1]]]))
        await viewModel.send(query: "Première question ?")
        #expect(viewModel.canRegenerate(afterReading: Self.refusedURL))
        await viewModel.send(query: "Seconde question ?")

        // La source refusée n'appartient qu'à la première réponse, qui n'est plus la dernière.
        #expect(!viewModel.canRegenerate(afterReading: Self.refusedURL))
        let streamsBefore = provider.receivedStreamPrompts.count
        let outcome = await viewModel.readPage(url: Self.refusedURL) { _ in true }
        #expect(outcome == .readOnly)
        #expect(provider.receivedStreamPrompts.count == streamsBefore)
    }

    @Test("Génération en cours : pas de lecture ni de seconde génération")
    func noSecondGenerationWhileGenerating() async throws {
        let provider = ChatViewModelTests.ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(provider: provider)
        viewModel.startSend(query: "Que dit l'article ?")
        for _ in 0..<2_000 where !viewModel.isGenerating || provider.continuation == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        try #require(viewModel.isGenerating)
        let streamsBefore = provider.receivedPrompts.count

        #expect(!viewModel.canReadPage)
        #expect(!viewModel.canRegenerate(afterReading: Self.refusedURL))
        var readerCalled = false
        let outcome = await viewModel.readPage(url: Self.refusedURL) { _ in readerCalled = true; return true }
        #expect(outcome == .failed)
        #expect(!readerCalled)

        await viewModel.regenerateLastAnswerWithReadPages()
        viewModel.startRegenerationWithReadPages()
        #expect(provider.receivedPrompts.count == streamsBefore)
        #expect(viewModel.messages.count == 2)

        provider.continuation?.yield("Fin.")
        provider.continuation?.finish()
        for _ in 0..<2_000 where viewModel.isGenerating {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(viewModel.canReadPage)
    }

    @Test("Une URL qui n'est pas parmi les sources de la dernière réponse ne déclenche rien")
    func unrelatedURLDoesNotRegenerate() async throws {
        let provider = ChatViewModelTests.MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(provider: provider)
        await viewModel.send(query: "Que dit l'article ?")

        #expect(viewModel.canRegenerate(afterReading: Self.refusedURL))
        #expect(!viewModel.canRegenerate(afterReading: "https://inconnu.example/x"))
    }

    @Test("Une source lue par l'utilisateur est relue en mémoire avant le rédacteur, même avec un extrait ; les autres non")
    func userReadSourceIsPreReadEvenWithAnExcerpt() {
        UserReadPages.removeAll()
        defer { UserReadPages.removeAll() }
        #expect(SearchOrchestrator.urlsToPreRead(Self.results).isEmpty)

        UserReadPages.store(readPage())

        #expect(SearchOrchestrator.urlsToPreRead(Self.results) == [Self.refusedURL])
    }
}
