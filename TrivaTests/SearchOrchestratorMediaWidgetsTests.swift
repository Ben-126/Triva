//
//  SearchOrchestratorMediaWidgetsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Contrat étendu : widgets, médias, mode connus AVANT le flux (I1b)

extension SearchOrchestratorStreamingTests {
    private static func image(_ name: String) -> ImageSearchResult {
        ImageSearchResult(
            imageURL: URL(string: "https://img.example/\(name).jpg")!,
            sourceURL: URL(string: "https://source.example/\(name)")!,
            title: "Image \(name)"
        )
    }

    private static func video(_ name: String) -> VideoSearchResult {
        VideoSearchResult(
            thumbnailURL: URL(string: "https://img.example/\(name).jpg")!,
            sourceURL: URL(string: "https://video.example/\(name)")!,
            title: "Vidéo \(name)",
            embedURL: nil
        )
    }

    private static let weatherAndSearchJSON = #"{"classification":{"skipSearch":false,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"showWeatherWidget":true,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"chats mignons sous la pluie"}"#

    @Test("Contrat 0.8 étendu : widgets, médias, mode et compte citable sont dans artifacts AVANT toute lecture du flux")
    func artifactsAreCompleteBeforeTheStreamIsRead() async throws {
        let results = Array(Self.sevenResults().prefix(2))
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = StreamingMockAIGenerating(chunks: ["Il ", "pleut."], classifyResponse: Self.weatherAndSearchJSON)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StreamingFixedOutputWidget(kind: .weather, llmContext: "Météo à Paris : pluie, 12 °C.")],
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [Self.video("b")], behavior: .results, log: MediaCallLog())
        )

        let answer = try await orchestrator.streamAnswer(query: "Des chats sous la pluie ?", media: .all)

        // Rien n'a encore été lu dans le flux : tout ce qui suit est déjà là.
        #expect(answer.sources == results)
        #expect(answer.artifacts.widgets.map(\.kind) == [.weather])
        #expect(answer.artifacts.images.items.map(\.title) == ["Image a"])
        #expect(answer.artifacts.videos.items.map(\.title) == ["Vidéo b"])
        #expect(answer.artifacts.mode == .deep)
        #expect(answer.artifacts.promptComplexity == .full)
        #expect(answer.artifacts.citableSourceCount == 2)
        #expect(answer.artifacts.attachmentSourceCount == 0)
        #expect(answer.artifacts.searchPerformed)
        #expect(answer.artifacts.searchQuery == "chats mignons sous la pluie")
        let streamPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(streamPrompt.contains("Météo à Paris : pluie, 12 °C."))

        var lastChunk = ""
        for try await chunk in answer.textStream {
            lastChunk = chunk
        }
        #expect(lastChunk == "pleut.")
    }

    @Test("Médias EN PARALLÈLE de la recherche texte, jamais en série : les deux se rejoignent pendant leur exécution")
    func mediaRunsInParallelWithTextSearch() async throws {
        let rendezvous = Rendezvous()
        let client = RendezvousSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []), rendezvous: rendezvous)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(),
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .rendezvous(rendezvous), log: MediaCallLog()),
            mediaGracePeriod: .seconds(5)
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .images)

        #expect(await rendezvous.sawPartner == ["texte": true, "médias": true])
        #expect(answer.artifacts.images.items.map(\.title) == ["Image a"])
        #expect(answer.artifacts.videos.items.isEmpty)
    }

    @Test("Médias non demandés (défaut) : aucune recherche média, aucun appel de plus ; .notRequested")
    func mediaIsNotSearchedUnlessRequested() async throws {
        let log = MediaCallLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(),
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [Self.video("b")], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons")

        #expect(await log.calls.isEmpty)
        #expect(await client.receivedQueries.count == 1)
        guard case .notRequested = answer.artifacts.images, case .notRequested = answer.artifacts.videos else {
            Issue.record("médias attendus .notRequested")
            return
        }
    }

    @Test("Seuls les médias demandés sont cherchés, avec la REFORMULATION du classifieur (aucun appel LLM de plus)")
    func onlyRequestedMediaAreSearchedWithTheReformulation() async throws {
        let log = MediaCallLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "chats mignons"))
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [], videos: [Self.video("b")], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "et en vidéo ?", media: .videos)

        #expect(await log.calls == ["vidéos:chats mignons"])
        #expect(answer.artifacts.videos.items.map(\.title) == ["Vidéo b"])
        guard case .notRequested = answer.artifacts.images else {
            Issue.record("images attendues .notRequested")
            return
        }
        // Classification seule : aucune reformulation média par LLM.
        #expect(aiProvider.receivedGeneratePrompts.count == 1)
    }

    @Test("Échec des médias : .failed, la réponse texte arrive quand même — jamais d'erreur levée pour un média")
    func mediaFailureNeverFailsTheAnswer() async throws {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(chunks: ["réponse"]),
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [], videos: [], behavior: .failure, log: MediaCallLog())
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .all)

        guard case .failed = answer.artifacts.images, case .failed = answer.artifacts.videos else {
            Issue.record("médias attendus .failed")
            return
        }
        #expect(answer.sources.count == 3)
        var received: [String] = []
        for try await chunk in answer.textStream {
            received.append(chunk)
        }
        #expect(received == ["réponse"])
    }

    @Test("Médias trop lents : abandonnés après le délai de grâce (.failed), la réponse ne les attend pas", .timeLimit(.minutes(1)))
    func slowMediaIsAbandonedAfterTheGracePeriod() async throws {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        // Le délai de grâce est une porte, pas une durée : elle s'ouvre quand le minuteur de grâce a
        // démarré (la recherche texte est finie), quelle que soit la charge. Des médias qui ne finissent
        // qu'au bout de 30 s ne peuvent alors être `.failed` que si la réponse a cessé de les attendre.
        let grace = GateClock()
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(),
            responseMode: .quick,
            clock: grace,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .sleep(.seconds(30)), log: MediaCallLog()),
            mediaGracePeriod: .milliseconds(20)
        )
        let driver = Task {
            while grace.sleeperCount < 1 { try? await Task.sleep(for: .milliseconds(1)) }
            grace.open()
        }
        defer { driver.cancel() }

        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .images)

        guard case .failed = answer.artifacts.images else {
            Issue.record("images attendues .failed")
            return
        }
        #expect(answer.sources.count == 3)
    }

    @Test("Sans recherche web (question conversationnelle), aucun média même demandé : .notRequested, aucun appel")
    func noMediaWithoutWebSearch() async throws {
        let log = MediaCallLog()
        let client = StreamingMockSearXNGClient()
        let aiProvider = StreamingMockAIGenerating(classifyResponse: Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Bonjour"))
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "Bonjour !", media: .all)

        #expect(await log.calls.isEmpty)
        #expect(await client.receivedQueries.isEmpty)
        #expect(answer.artifacts.searchPerformed == false)
        guard case .notRequested = answer.artifacts.images else {
            Issue.record("images attendues .notRequested")
            return
        }
    }

    @Test("SearXNGMediaSearcher : catégories et moteurs des services de 1.6, requête telle quelle, filtrage https des services")
    func searXNGMediaSearcherUsesMediaCategories() async throws {
        let results = [
            SearXNGSearchResult(
                title: "Chat", url: "https://chats.example/1", content: nil,
                imgSrc: "https://img.example/1.jpg", thumbnailSrc: nil, thumbnail: "https://img.example/1-small.jpg",
                author: nil, iframeSrc: nil
            ),
            SearXNGSearchResult(
                title: "Chat non sécurisé", url: "https://chats.example/2", content: nil,
                imgSrc: "http://img.example/2.jpg", thumbnailSrc: nil, thumbnail: "http://img.example/2-small.jpg",
                author: nil, iframeSrc: nil
            ),
        ]
        let client = OptionsRecordingSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let searcher = SearXNGMediaSearcher(failoverManager: FailoverManager(client: client, instances: [Self.instance]))

        let images = try await searcher.searchImages(query: "chats mignons")
        let videos = try await searcher.searchVideos(query: "chats mignons")

        #expect(images.map(\.title) == ["Chat"])
        #expect(videos.map(\.title) == ["Chat"])
        #expect(await client.receivedOptions == [SearXNGMediaSearcher.imageSearchOptions, SearXNGMediaSearcher.videoSearchOptions])
        #expect(SearXNGMediaSearcher.imageSearchOptions == SearXNGSearchOptions(categories: ["images"], engines: ["bing images", "google images"]))
        #expect(SearXNGMediaSearcher.videoSearchOptions == SearXNGSearchOptions(categories: ["videos"], engines: ["youtube"]))
        #expect(await client.receivedQueries == ["chats mignons", "chats mignons"])
    }
}
