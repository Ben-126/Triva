//
//  GenerationStageTests.swift
//  TrivaTests
//
//  Mission C6 : « Réflexion… » tant que la question est analysée ; « Recherche des sources… » seulement
//  quand Triva cherche vraiment (jamais pour une salutation).
//

import Testing
import Foundation
@testable import Triva

private func classification(skipSearch: Bool) -> String {
    """
    {"classification":{"skipSearch":\(skipSearch),"personalSearch":false,"academicSearch":false,\
    "discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,\
    "showCalculationWidget":false},"standaloneFollowUp":"Question"}
    """
}

/// Fournisseur dont la classification reste suspendue jusqu'à `releaseClassification()`.
private final class GatedClassifierProvider: AIGenerating, @unchecked Sendable {
    private let json: String
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(skipSearch: Bool) { json = classification(skipSearch: skipSearch) }

    func generate(prompt: String) async throws -> String {
        guard prompt.contains("<user_query>") else { return "" }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { gate = continuation }
        }
        return json
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("Réponse."); $0.finish() }
    }

    func releaseClassification() {
        released = true
        gate?.resume()
        gate = nil
    }
}

/// Client SearXNG dont la recherche reste en vol jusqu'à `release()`.
private actor HoldingSearXNGClient: SearXNGSearching {
    private var pending: CheckedContinuation<SearXNGSearchResponse, Error>?
    private(set) var searchCount = 0

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        searchCount += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func release() {
        pending?.resume(returning: SearXNGSearchResponse(results: [], suggestions: []))
        pending = nil
    }
}

@MainActor
private final class CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

extension ChatViewModelTests {
    private func orchestrator(provider: any AIGenerating, client: any SearXNGSearching) -> SearchOrchestrator {
        SearchOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: provider,
            responseMode: .quick,
            configuration: .cloud,
            scrapeService: FailingScrapeService(),
            sourceRanker: Self.orderPreservingRanker(),
            widgets: []
        )
    }

    @Test("Pendant la classification : « Réflexion… », pas « Recherche des sources… » (échoue avec l'ancien défaut)")
    func stageIsAnalyzingWhileTheQuestionIsClassified() async {
        let provider = GatedClassifierProvider(skipSearch: true)
        let viewModel = makeViewModel(resolveProvider: { provider })

        viewModel.startSend(query: "Bonjour")
        await waitUntil("réponse en attente") { viewModel.messages.last?.role == .assistant }

        #expect(viewModel.messages.last?.generationStage == .analyzing)
        #expect(GenerationStage.analyzing.statusText == "Réflexion…")

        provider.releaseClassification()
        await waitUntil("échange terminé") { !viewModel.isGenerating }
        // Une salutation ne cherche rien : la ligne d'état n'a jamais pu annoncer de recherche.
        #expect(viewModel.messages.last?.generationStage != .searching)
    }

    @Test("Vraie recherche : « Réflexion… » puis « Recherche des sources… » une fois la classification finie")
    func stageBecomesSearchingWhenSearchStarts() async {
        let provider = GatedClassifierProvider(skipSearch: false)
        let client = HoldingSearXNGClient()
        let viewModel = makeViewModel(resolveProvider: { provider }, client: client)

        viewModel.startSend(query: "Quelle est la hauteur de la tour Eiffel ?")
        await waitUntil("réponse en attente") { viewModel.messages.last?.role == .assistant }
        #expect(viewModel.messages.last?.generationStage == .analyzing)

        provider.releaseClassification()
        await waitUntil("la recherche est lancée") { viewModel.messages.last?.generationStage == .searching }
        #expect(viewModel.messages.last?.generationStage == .searching)

        viewModel.stop()
        await client.release()
        await waitUntil("échange arrêté") { !viewModel.isGenerating }
    }

    @Test("L'orchestrateur n'annonce une recherche que si la question en lance une", arguments: [(true, 0), (false, 1)])
    func orchestratorAnnouncesSearchOnlyWhenSearching(skipSearch: Bool, expectedAnnouncements: Int) async throws {
        let provider = GatedClassifierProvider(skipSearch: skipSearch)
        provider.releaseClassification()
        let orchestrator = orchestrator(provider: provider, client: MockSearXNGClient())
        let announcements = CallCounter()

        _ = try await orchestrator.streamAnswer(
            query: "Bonjour", onSearchStarted: { announcements.increment() }
        )

        #expect(announcements.count == expectedAnnouncements)
    }
}
