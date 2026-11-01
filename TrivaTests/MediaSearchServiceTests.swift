//
//  MediaSearchServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures

/// Client SearXNG factice — même principe que `FailoverManagerTests.MockSearXNGClient`,
/// mais journalise aussi `query`/`options` (pas seulement `instance`) : ce
/// fichier vérifie la CATÉGORIE/les ENGINES envoyés, ce que
/// `FailoverManagerTests` n'a pas besoin de faire.
private actor MockSearXNGClient: SearXNGSearching {
    enum Behavior: Sendable {
        case success(SearXNGSearchResponse)
        case failure(any Error)
    }

    private let behavior: Behavior
    private(set) var receivedQuery: String?
    private(set) var receivedOptions: SearXNGSearchOptions?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedQuery = query
        receivedOptions = options
        switch behavior {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

private enum StubMediaError: Error, Sendable, Equatable {
    case boom
}

/// Provider IA factice pour la reformulation : trois comportements couvrent
/// les trois chemins de `MediaSearchQueryReformulator.reformulate`.
private struct StubAIProvider: AIGenerating {
    enum Behavior: Sendable {
        case success(String)
        case failure
    }

    let behavior: Behavior

    func generate(prompt: String) async throws -> String {
        switch behavior {
        case .success(let text): return text
        case .failure: throw StubMediaError.boom
        }
    }
}

private func makeFailoverManager(client: MockSearXNGClient) -> FailoverManager {
    FailoverManager(client: client, instances: [URL(string: "https://searx.example")!])
}

// MARK: - ImageSearchService

@MainActor
@Suite("ImageSearchService")
struct ImageSearchServiceTests {
    private func searxngResult(title: String = "Un chat", imgSrc: String? = "https://img.example/cat.jpg", url: String? = "https://source.example/cat") -> SearXNGSearchResult {
        SearXNGSearchResult(title: title, url: url ?? "", content: nil, imgSrc: imgSrc, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil)
    }

    @Test("Mappe un résultat SearXNG valide en ImageSearchResult")
    func mapsValidResult() {
        let mapped = ImageSearchService.filterAndMap([searxngResult()], maxResults: 10)

        #expect(mapped.count == 1)
        #expect(mapped[0].imageURL == URL(string: "https://img.example/cat.jpg"))
        #expect(mapped[0].sourceURL == URL(string: "https://source.example/cat"))
        #expect(mapped[0].title == "Un chat")
    }

    @Test("Rejette un résultat sans img_src")
    func rejectsMissingImgSrc() {
        let mapped = ImageSearchService.filterAndMap([searxngResult(imgSrc: nil)], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat avec une URL en http (non https)")
    func rejectsNonHTTPSImage() {
        let mapped = ImageSearchService.filterAndMap(
            [searxngResult(imgSrc: "http://img.example/cat.jpg")],
            maxResults: 10
        )
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat avec un titre vide")
    func rejectsBlankTitle() {
        let mapped = ImageSearchService.filterAndMap([searxngResult(title: "   ")], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat sans url source valide")
    func rejectsMissingSourceURL() {
        let mapped = ImageSearchService.filterAndMap([searxngResult(url: "")], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Borne le nombre de résultats à maxResults")
    func boundsResultCount() {
        let results = (0..<15).map { index in
            searxngResult(title: "Chat \(index)", imgSrc: "https://img.example/\(index).jpg", url: "https://source.example/\(index)")
        }
        let mapped = ImageSearchService.filterAndMap(results, maxResults: 10)
        #expect(mapped.count == 10)
    }

    @Test("search() utilise la catégorie images et les engines attendus")
    func usesImageSearchOptions() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [searxngResult()], suggestions: [])))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        _ = try await service.search(query: "chats mignons")

        let options = await client.receivedOptions
        #expect(options?.categories == ["images"])
        #expect(options?.engines == ["bing images", "google images"])
    }

    @Test("search() utilise la requête reformulée par le LLM quand elle est valide")
    func usesReformulatedQueryOnSuccess() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .success(#"{"query": "photos Japon"}"#))
        )

        _ = try await service.search(query: "montre-moi des photos", chatHistory: [ClassifierChatMessage(role: .user, content: "Parle-moi du Japon")])

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "photos Japon")
    }

    @Test("search() se replie sur la requête originale si le LLM échoue")
    func fallsBackToOriginalQueryOnLLMFailure() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        _ = try await service.search(query: "chats mignons")

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "chats mignons")
    }

    @Test("search() se replie sur la requête originale si la sortie du LLM n'est pas un JSON exploitable")
    func fallsBackToOriginalQueryOnUnparsableOutput() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .success("Désolé, je ne peux pas répondre."))
        )

        _ = try await service.search(query: "chats mignons")

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "chats mignons")
    }

    @Test("search() renvoie un tableau vide quand SearXNG ne trouve rien")
    func returnsEmptyArrayWhenNoResults() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        let results = try await service.search(query: "requête sans aucun résultat")
        #expect(results.isEmpty)
    }

    @Test("search() propage l'erreur quand l'instance SearXNG échoue")
    func propagatesInstanceError() async throws {
        let client = MockSearXNGClient(behavior: .failure(StubMediaError.boom))
        let service = ImageSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await service.search(query: "chats mignons")
        }
    }
}

// MARK: - VideoSearchService

@MainActor
@Suite("VideoSearchService")
struct VideoSearchServiceTests {
    private func searxngResult(
        title: String = "Une vidéo",
        thumbnail: String? = "https://img.example/thumb.jpg",
        url: String? = "https://youtube.example/watch",
        iframeSrc: String? = "https://youtube.example/embed"
    ) -> SearXNGSearchResult {
        SearXNGSearchResult(title: title, url: url ?? "", content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: thumbnail, author: nil, iframeSrc: iframeSrc)
    }

    @Test("Mappe un résultat SearXNG valide en VideoSearchResult, iframe incluse")
    func mapsValidResultWithEmbed() {
        let mapped = VideoSearchService.filterAndMap([searxngResult()], maxResults: 10)

        #expect(mapped.count == 1)
        #expect(mapped[0].thumbnailURL == URL(string: "https://img.example/thumb.jpg"))
        #expect(mapped[0].sourceURL == URL(string: "https://youtube.example/watch"))
        #expect(mapped[0].embedURL == URL(string: "https://youtube.example/embed"))
        #expect(mapped[0].title == "Une vidéo")
    }

    @Test("Mappe un résultat valide même sans iframe_src (divergence assumée vs le web)")
    func mapsValidResultWithoutEmbed() {
        let mapped = VideoSearchService.filterAndMap([searxngResult(iframeSrc: nil)], maxResults: 10)

        #expect(mapped.count == 1)
        #expect(mapped[0].embedURL == nil)
        #expect(mapped[0].sourceURL == URL(string: "https://youtube.example/watch"))
    }

    @Test("Rejette un résultat sans vignette")
    func rejectsMissingThumbnail() {
        let mapped = VideoSearchService.filterAndMap([searxngResult(thumbnail: nil)], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat avec une vignette en http (non https)")
    func rejectsNonHTTPSThumbnail() {
        let mapped = VideoSearchService.filterAndMap(
            [searxngResult(thumbnail: "http://img.example/thumb.jpg")],
            maxResults: 10
        )
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat avec un titre vide")
    func rejectsBlankTitle() {
        let mapped = VideoSearchService.filterAndMap([searxngResult(title: "")], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Rejette un résultat sans url source valide")
    func rejectsMissingSourceURL() {
        let mapped = VideoSearchService.filterAndMap([searxngResult(url: nil)], maxResults: 10)
        #expect(mapped.isEmpty)
    }

    @Test("Borne le nombre de résultats à maxResults")
    func boundsResultCount() {
        let results = (0..<15).map { index in
            searxngResult(title: "Vidéo \(index)", thumbnail: "https://img.example/\(index).jpg", url: "https://youtube.example/\(index)")
        }
        let mapped = VideoSearchService.filterAndMap(results, maxResults: 10)
        #expect(mapped.count == 10)
    }

    @Test("search() utilise la catégorie videos et l'engine youtube")
    func usesVideoSearchOptions() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [searxngResult()], suggestions: [])))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        _ = try await service.search(query: "chats mignons")

        let options = await client.receivedOptions
        #expect(options?.categories == ["videos"])
        #expect(options?.engines == ["youtube"])
    }

    @Test("search() utilise la requête reformulée par le LLM quand elle est valide")
    func usesReformulatedQueryOnSuccess() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .success(#"{"query": "vidéo photosynthèse"}"#))
        )

        _ = try await service.search(query: "montre-moi des vidéos", chatHistory: [ClassifierChatMessage(role: .user, content: "Comment fonctionne la photosynthèse ?")])

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "vidéo photosynthèse")
    }

    @Test("search() se replie sur la requête originale si le LLM échoue")
    func fallsBackToOriginalQueryOnLLMFailure() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        _ = try await service.search(query: "chats mignons")

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "chats mignons")
    }

    @Test("search() se replie sur la requête originale si la sortie du LLM n'est pas un JSON exploitable")
    func fallsBackToOriginalQueryOnUnparsableOutput() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .success("pas de json ici"))
        )

        _ = try await service.search(query: "chats mignons")

        let receivedQuery = await client.receivedQuery
        #expect(receivedQuery == "chats mignons")
    }

    @Test("search() renvoie un tableau vide quand SearXNG ne trouve rien")
    func returnsEmptyArrayWhenNoResults() async throws {
        let client = MockSearXNGClient(behavior: .success(SearXNGSearchResponse(results: [], suggestions: [])))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        let results = try await service.search(query: "requête sans aucun résultat")
        #expect(results.isEmpty)
    }

    @Test("search() propage l'erreur quand l'instance SearXNG échoue")
    func propagatesInstanceError() async throws {
        let client = MockSearXNGClient(behavior: .failure(StubMediaError.boom))
        let service = VideoSearchService(
            failoverManager: makeFailoverManager(client: client),
            aiProvider: StubAIProvider(behavior: .failure)
        )

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await service.search(query: "chats mignons")
        }
    }
}

// MARK: - MediaSearchQueryReformulator (parsing tolérant, unité isolée)

@MainActor
@Suite("MediaSearchQueryReformulator")
struct MediaSearchQueryReformulatorTests {
    @Test("Parse un JSON brut")
    func parsesRawJSON() {
        #expect(MediaSearchQueryReformulator.parseQuery(#"{"query": "chats mignons"}"#) == "chats mignons")
    }

    @Test("Parse un JSON entouré de texte et d'un bloc de code markdown")
    func parsesFencedJSONWithSurroundingText() {
        let raw = "Voici ma réponse :\n```json\n{\"query\": \"chats mignons\"}\n```\nEn espérant que ça convient."
        #expect(MediaSearchQueryReformulator.parseQuery(raw) == "chats mignons")
    }

    @Test("Renvoie nil sur une sortie sans JSON")
    func returnsNilOnNonJSON() {
        #expect(MediaSearchQueryReformulator.parseQuery("je ne sais pas") == nil)
    }

    @Test("Renvoie nil sur un JSON dont le champ query est absent")
    func returnsNilOnMissingQueryField() {
        #expect(MediaSearchQueryReformulator.parseQuery(#"{"other": "chats mignons"}"#) == nil)
    }
}
