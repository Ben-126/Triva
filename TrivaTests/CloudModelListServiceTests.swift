//
//  CloudModelListServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux client HTTP : réponse ou erreur fixée, requêtes reçues enregistrées.
/// Aucun appel réseau réel.
private final class MockRequester: HTTPDataRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let statusCode: Int
    private let body: String
    private let error: (any Error)?

    init(statusCode: Int = 200, body: String = "", error: (any Error)? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.error = error
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let secretKey = "sk-test-SECRET-1234567890"
private let openAISource = CloudModelListSource.openAICompatible(baseURL: URL(string: "https://api.example.com/v1")!)

private func makeService(_ requester: MockRequester) -> CloudModelListService {
    CloudModelListService(requester: requester, cache: CloudModelListCache())
}

@Suite("CloudModelListService")
struct CloudModelListServiceTests {
    // MARK: - Décodage

    @Test("Format OpenAI : décode, filtre les modèles non textuels, dédoublonne et trie")
    func decodesOpenAIFormat() async throws {
        let requester = MockRequester(body: """
        {"object":"list","data":[
          {"id":"gpt-4o-mini"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},
          {"id":"dall-e-3"},{"id":"omni-moderation-latest"},{"id":"tts-1"},
          {"id":"gpt-4o"},{"id":"gpt-4o"},{"id":"gpt-10"},{"id":"gpt-9"}
        ]}
        """)

        let models = try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)

        #expect(models.map(\.id) == ["gpt-4o", "gpt-4o-mini", "gpt-9", "gpt-10"])
    }

    @Test("Format Anthropic : garde display_name et l'ordre de l'API")
    func decodesAnthropicFormat() async throws {
        let requester = MockRequester(body: """
        {"data":[
          {"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5","created_at":"2026-07-24T00:00:00Z"},
          {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"}
        ],"has_more":false,"first_id":null,"last_id":null}
        """)

        let models = try await makeService(requester).models(providerID: "claude", source: .anthropic, apiKey: secretKey)

        #expect(models == [
            CloudModelOption(id: "claude-opus-5", displayName: "Claude Opus 5"),
            CloudModelOption(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
        ])
    }

    @Test("Format Gemini : ne garde que generateContent et retire le préfixe models/")
    func decodesGeminiFormat() async throws {
        let requester = MockRequester(body: """
        {"models":[
          {"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding-004","displayName":"Text Embedding 004","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/aqa","displayName":"AQA"}
        ]}
        """)

        let models = try await makeService(requester).models(providerID: "gemini", source: .gemini, apiKey: secretKey)

        #expect(models == [
            CloudModelOption(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            CloudModelOption(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro"),
        ])
    }

    @Test("Corps illisible → erreur de décodage")
    func undecodableBodyThrowsDecoding() async {
        let requester = MockRequester(body: "<html>oops</html>")

        await #expect(throws: CloudModelListError.decoding) {
            try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
        }
    }

    @Test("Liste fixe (Perplexity) : aucun appel réseau")
    @MainActor
    func staticListMakesNoRequest() async throws {
        let requester = MockRequester()
        let source = try #require(CloudModelListService.source(forProviderID: "perplexity", customPresets: []))

        let models = try await makeService(requester).models(providerID: "perplexity", source: source, apiKey: secretKey)

        #expect(models.map(\.id) == ["fast", "low", "medium", "high", "xhigh"])
        #expect(requester.requests.isEmpty)
    }

    // MARK: - Requêtes

    @Test("Requête OpenAI : {baseURL}/models + Bearer, avec ou sans slash final")
    func openAIRequestShape() {
        let request = CloudModelListService.request(for: openAISource, apiKey: secretKey)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secretKey)")
        #expect(request.httpMethod == "GET")

        let slashed = CloudModelListService.request(
            for: .openAICompatible(baseURL: URL(string: "https://api.example.com/v1/")!),
            apiKey: secretKey
        )
        #expect(slashed.url?.absoluteString == "https://api.example.com/v1/models")
    }

    @Test("Requête Anthropic : x-api-key + anthropic-version")
    func anthropicRequestShape() {
        let request = CloudModelListService.request(for: .anthropic, apiKey: secretKey)
        #expect(request.url?.host() == "api.anthropic.com")
        #expect(request.url?.path() == "/v1/models")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == secretKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Requête Gemini : clé en en-tête, jamais dans l'URL")
    func geminiRequestKeepsKeyOutOfURL() {
        let request = CloudModelListService.request(for: .gemini, apiKey: secretKey)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == secretKey)
        #expect(request.url?.absoluteString.contains(secretKey) == false)
        #expect(request.url?.path() == "/v1beta/models")
    }

    @Test("Le délai de la requête est court")
    func requestTimeoutIsShort() {
        let request = CloudModelListService.request(for: openAISource, apiKey: secretKey)
        #expect(request.timeoutInterval == CloudModelListService.requestTimeout)
        #expect(CloudModelListService.requestTimeout <= 15)
    }

    @Test("Source : Claude, Gemini, catalogue, personnalisé, inconnu")
    @MainActor
    func sourceMapping() {
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "m"
        )
        #expect(CloudModelListService.source(forProviderID: "claude", customPresets: []) == .anthropic)
        #expect(CloudModelListService.source(forProviderID: "gemini", customPresets: []) == .gemini)
        #expect(CloudModelListService.source(forProviderID: "groq", customPresets: [])
                == .openAICompatible(baseURL: URL(string: "https://api.groq.com/openai/v1")!))
        #expect(CloudModelListService.source(forProviderID: "custom:abc", customPresets: [custom])
                == .openAICompatible(baseURL: custom.baseURL))
        #expect(CloudModelListService.source(forProviderID: "inconnu", customPresets: []) == nil)
    }

    // MARK: - Erreurs

    @Test("Statuts HTTP → erreurs typées", arguments: [
        (401, CloudModelListError.invalidKey),
        (403, CloudModelListError.forbidden),
        (429, CloudModelListError.rateLimited),
        (500, CloudModelListError.serverUnavailable),
        (503, CloudModelListError.serverUnavailable),
        (404, CloudModelListError.listUnavailable),
        (405, CloudModelListError.listUnavailable),
        (501, CloudModelListError.listUnavailable),
        (418, CloudModelListError.unexpectedStatus(418)),
    ])
    func httpStatusMapsToTypedError(statusCode: Int, expected: CloudModelListError) async {
        let requester = MockRequester(statusCode: statusCode, body: #"{"error":{"message":"bad key \#(secretKey)"}}"#)

        await #expect(throws: expected) {
            try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
        }
    }

    @Test("Timeout réseau → .timeout")
    func timeoutMapsToTimeoutError() async {
        let requester = MockRequester(error: URLError(.timedOut))

        await #expect(throws: CloudModelListError.timeout) {
            try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
        }
    }

    @Test("Hors connexion → .network")
    func offlineMapsToNetworkError() async {
        let requester = MockRequester(error: URLError(.notConnectedToInternet))

        await #expect(throws: CloudModelListError.network) {
            try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
        }
    }

    @Test("Annulation propagée telle quelle, pas maquillée en erreur réseau")
    func cancellationIsPropagated() async {
        let requester = MockRequester(error: URLError(.cancelled))

        await #expect(throws: CancellationError.self) {
            try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
        }
    }

    @Test("Aucun message d'erreur ne contient la clé")
    func errorMessagesNeverContainKey() async {
        let all: [CloudModelListError] = [
            .invalidKey, .forbidden, .rateLimited, .serverUnavailable,
            .unexpectedStatus(418), .timeout, .network, .listUnavailable, .decoding,
        ]
        for error in all {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains(secretKey))
            #expect(!String(describing: error).contains(secretKey))
        }

        // Même quand le corps d'erreur du fournisseur renvoie la clé.
        let requester = MockRequester(statusCode: 401, body: #"{"error":{"message":"Incorrect API key \#(secretKey)"}}"#)
        do {
            _ = try await makeService(requester).models(providerID: "openai", source: openAISource, apiKey: secretKey)
            Issue.record("Une erreur était attendue")
        } catch {
            #expect(!String(describing: error).contains(secretKey))
            #expect(!error.localizedDescription.contains(secretKey))
        }
    }

    @Test("Seuls l'endpoint absent et le format inconnu signifient « liste impossible »")
    func onlyPermanentErrorsMeanListUnavailable() {
        #expect(CloudModelListError.listUnavailable.meansListUnavailable)
        #expect(CloudModelListError.decoding.meansListUnavailable)
        let temporary: [CloudModelListError] = [
            .invalidKey, .forbidden, .rateLimited, .serverUnavailable,
            .unexpectedStatus(418), .timeout, .network,
        ]
        for error in temporary {
            #expect(!error.meansListUnavailable)
        }
    }

    // MARK: - Cache

    @Test("Deuxième appel servi par le cache, sans nouvelle requête")
    func secondCallUsesCache() async throws {
        let requester = MockRequester(body: #"{"data":[{"id":"m1"}]}"#)
        let service = makeService(requester)

        _ = try await service.models(providerID: "openai", source: openAISource, apiKey: secretKey)
        let second = try await service.models(providerID: "openai", source: openAISource, apiKey: secretKey)

        #expect(second.map(\.id) == ["m1"])
        #expect(requester.requests.count == 1)
    }

    @Test("Autre clé ou forceRefresh → nouvelle requête")
    func otherKeyOrForceRefreshBypassesCache() async throws {
        let requester = MockRequester(body: #"{"data":[{"id":"m1"}]}"#)
        let service = makeService(requester)

        _ = try await service.models(providerID: "openai", source: openAISource, apiKey: secretKey)
        _ = try await service.models(providerID: "openai", source: openAISource, apiKey: "sk-autre")
        _ = try await service.models(providerID: "openai", source: openAISource, apiKey: secretKey, forceRefresh: true)

        #expect(requester.requests.count == 3)
    }

    @Test("Une erreur n'est pas mise en cache")
    func errorsAreNotCached() async throws {
        let failing = MockRequester(statusCode: 500)
        let cache = CloudModelListCache()
        let failingService = CloudModelListService(requester: failing, cache: cache)
        _ = try? await failingService.models(providerID: "openai", source: openAISource, apiKey: secretKey)

        let working = MockRequester(body: #"{"data":[{"id":"m1"}]}"#)
        let models = try await CloudModelListService(requester: working, cache: cache)
            .models(providerID: "openai", source: openAISource, apiKey: secretKey)

        #expect(models.map(\.id) == ["m1"])
        #expect(working.requests.count == 1)
    }

    @Test("Entrée de cache expirée ignorée")
    func expiredCacheEntryIsIgnored() async {
        let cache = CloudModelListCache(lifetime: 60)
        let now = Date()
        await cache.store([CloudModelOption(id: "m1", displayName: "m1")], for: "k", now: now)

        #expect(await cache.models(for: "k", now: now.addingTimeInterval(30))?.count == 1)
        #expect(await cache.models(for: "k", now: now.addingTimeInterval(61)) == nil)
    }

    @Test("La clé de cache ne contient pas la clé API")
    func cacheKeyDoesNotContainAPIKey() {
        let key = CloudModelListService.cacheKey(providerID: "openai", apiKey: secretKey)
        #expect(!key.contains(secretKey))
        #expect(key.hasPrefix("openai|"))
        #expect(key != CloudModelListService.cacheKey(providerID: "openai", apiKey: "sk-autre"))
    }
}
