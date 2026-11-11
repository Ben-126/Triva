//
//  APIKeyNotCachedTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// `URLProtocol` qui répond 200 « cachable » (`Cache-Control: max-age`) à tout,
/// avec la politique de stockage `.allowed` : si une requête PEUT atterrir dans
/// le `URLCache`, elle y atterrira. Sans ça, un test « rien n'est en cache »
/// passerait pour la mauvaise raison (réponse non cachable).
private final class CacheableStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "application/json"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Session configurée COMME `URLSession.shared` (configuration `.default`, donc
/// cache disque actif) mais sur un `URLCache` jetable et sans réseau réel. Les
/// clients testés (`OpenAICompatibleClient`, `PerplexityAgentClient`) utilisent
/// `.shared` par défaut : ce banc reproduit son comportement de cache.
private func makeSharedLikeSession(cache: URLCache) -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = cache
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.protocolClasses = [CacheableStubProtocol.self]
    return URLSession(configuration: configuration)
}

/// Tout le contenu des fichiers du dossier du cache, pour y chercher la clé en
/// clair (elle s'était retrouvée dans la table `cfurl_cache_blob_data`).
private func cacheFilesContain(_ needle: String, in directory: URL) -> Bool {
    let needleData = Data(needle.utf8)
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return false
    }
    for case let file as URL in enumerator {
        if let data = try? Data(contentsOf: file), data.range(of: needleData) != nil {
            return true
        }
    }
    return false
}

@MainActor
@Suite("Clés API jamais écrites dans le cache HTTP", .serialized)
struct APIKeyNotCachedTests {
    private static let secret = "sk-test-CLE-SECRETE-A-NE-JAMAIS-VOIR-SUR-DISQUE"

    private func makeCache() -> (URLCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "triva-key-cache-\(UUID().uuidString)")
        return (URLCache(memoryCapacity: 2_000_000, diskCapacity: 2_000_000, directory: directory), directory)
    }

    @Test("Témoin : le banc détecte bien un GET qui entre dans le cache")
    func controlGetIsCached() async throws {
        let (cache, _) = makeCache()
        let session = makeSharedLikeSession(cache: cache)
        let url = try #require(URL(string: "https://api.openai.com/v1/models"))
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Self.secret)", forHTTPHeaderField: "Authorization")

        _ = try await session.data(for: request)

        #expect(cache.cachedResponse(for: request) != nil)
    }

    @Test("OpenAICompatibleClient : ni réponse ni clé dans le cache après une requête")
    func openAICompatibleClientLeavesNoKeyInCache() async throws {
        let (cache, directory) = makeCache()
        let client = OpenAICompatibleClient(urlSession: makeSharedLikeSession(cache: cache))
        let baseURL = try #require(URL(string: "https://api.groq.com/openai/v1"))

        _ = try await client.generate(baseURL: baseURL, apiKey: Self.secret, model: "m", prompt: "Bonjour")

        let request = try OpenAICompatibleClient.buildRequest(
            url: CloudProviderCatalog.chatCompletionsURL(baseURL: baseURL),
            apiKey: Self.secret, model: "m", prompt: "Bonjour", timeoutInterval: 30
        )
        #expect(cache.cachedResponse(for: request) == nil)
        #expect(cache.currentDiskUsage == 0)
        #expect(!cacheFilesContain(Self.secret, in: directory))
    }

    @Test("PerplexityAgentClient : ni réponse ni clé dans le cache (requête simple et flux)")
    func perplexityClientLeavesNoKeyInCache() async throws {
        let (cache, directory) = makeCache()
        let client = PerplexityAgentClient(urlSession: makeSharedLikeSession(cache: cache))
        let baseURL = try #require(URL(string: "https://api.perplexity.ai"))

        // Le corps renvoyé par le banc n'est pas au format Perplexity : l'appel
        // peut échouer au décodage, ce qui n'importe pas ici — la requête, elle,
        // est bien partie avec la clé.
        _ = try? await client.generate(baseURL: baseURL, apiKey: Self.secret, model: "fast", prompt: "Bonjour")
        do {
            for try await _ in client.stream(baseURL: baseURL, apiKey: Self.secret, model: "fast", prompt: "Bonjour") {}
        } catch {}

        let request = try PerplexityAgentClient.buildRequest(
            baseURL: baseURL, apiKey: Self.secret, model: "fast", prompt: "Bonjour",
            stream: false, timeoutInterval: 90
        )
        #expect(cache.cachedResponse(for: request) == nil)
        #expect(cache.currentDiskUsage == 0)
        #expect(!cacheFilesContain(Self.secret, in: directory))
    }
}
