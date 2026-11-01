//
//  PerplexityAgentTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 28/10/2026.
//

import Testing
import Foundation
@testable import Triva

private struct PplxKeyStore: APIKeyStoring {
    var storedKey: String?
    var readError: (any Error)?

    func apiKey(account: String) throws -> String? {
        if let readError { throw readError }
        return storedKey
    }

    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private struct PplxStubError: Error {}

private struct MockPerplexityClient: PerplexityAgentRequesting {
    var events: [PerplexityStreamEvent] = []
    var streamError: (any Error)?
    var generated = "ok"

    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String { generated }

    func stream(baseURL: URL, apiKey: String, model: String, prompt: String) -> AsyncThrowingStream<PerplexityStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: streamError)
        }
    }
}

private let pplxBase = URL(string: "https://api.perplexity.ai")!

@MainActor
@Suite("PerplexityAgentClient")
struct PerplexityAgentClientTests {
    @Test("Requête : POST /v1/agent, clé en en-tête uniquement, effort + input + stream")
    func requestShape() throws {
        let request = try PerplexityAgentClient.buildRequest(
            baseURL: pplxBase, apiKey: "sk-secret", model: "low", prompt: "Bonjour", stream: true, timeoutInterval: 30
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.perplexity.ai/v1/agent")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(request.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains("sk-secret"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["effort"] as? String == "low")
        #expect(json["input"] as? String == "Bonjour")
        #expect(json["stream"] as? Bool == true)
        #expect(json["model"] == nil)
        // Pas de recherche web propre à Perplexity : il rédige à partir des sources de Triva.
        #expect(json["tool_choice"] as? String == "none")
    }

    @Test("Les anciens ids Sonar sont convertis en niveaux d'effort", arguments: [
        ("sonar", "fast"), ("sonar-pro", "fast"), ("sonar-reasoning-pro", "low"),
        ("sonar-deep-research", "high"), ("medium", "medium"), ("fast@2026-10-16.0", "fast@2026-10-16.0"),
        ("", "fast"), ("  ", "fast"),
    ])
    func effortMapping(model: String, expected: String) {
        #expect(PerplexityAgentClient.effort(forModel: model) == expected)
    }

    @Test("handles : uniquement l'hôte api.perplexity.ai")
    func handlesHost() {
        #expect(PerplexityAgentClient.handles(baseURL: pplxBase))
        #expect(!PerplexityAgentClient.handles(baseURL: URL(string: "https://api.groq.com/openai/v1")!))
        #expect(CloudChatClientFactory.client(forBaseURL: pplxBase) is PerplexityAgentClient)
        #expect(CloudChatClientFactory.client(forBaseURL: URL(string: "https://api.groq.com/openai/v1")!) is OpenAICompatibleClient)
    }

    @Test("Codes HTTP → erreurs fixes")
    func statusMapping() {
        #expect(PerplexityAgentClient.error(forStatusCode: 200) == nil)
        #expect(PerplexityAgentClient.error(forStatusCode: 401) == .invalidKey)
        #expect(PerplexityAgentClient.error(forStatusCode: 403) == .invalidKey)
        #expect(PerplexityAgentClient.error(forStatusCode: 429) == .rateLimited)
        #expect(PerplexityAgentClient.error(forStatusCode: 400) == .requestRejected)
        #expect(PerplexityAgentClient.error(forStatusCode: 503) == .serverError)
    }

    @Test("Les messages d'erreur ne contiennent aucun détail serveur")
    func fixedMessages() {
        let all: [PerplexityAgentError] = [
            .missingAPIKey, .keychainUnavailable, .invalidKey, .rateLimited, .requestRejected,
            .serverError, .transportError, .decodingFailed, .generationFailed,
        ]
        for error in all { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test("Annulation préservée, autres erreurs → transportError")
    func transportMapping() {
        #expect(PerplexityAgentClient.mapTransportError(CancellationError()) is CancellationError)
        #expect(PerplexityAgentClient.mapTransportError(URLError(.cancelled)) is CancellationError)
        #expect(PerplexityAgentClient.mapTransportError(URLError(.timedOut)) as? PerplexityAgentError == .transportError)
        #expect(PerplexityAgentClient.mapTransportError(PerplexityAgentError.rateLimited) as? PerplexityAgentError == .rateLimited)
    }

    @Test("SSE : delta de texte")
    func parsesDelta() throws {
        let line = #"data: {"type":"response.output_text.delta","delta":"Bon"}"#
        #expect(try PerplexityAgentClient.parseSSELine(line) == .textDelta("Bon"))
    }

    @Test("SSE : sources de recherche")
    func parsesSources() throws {
        let line = #"data: {"type":"response.reasoning.search_results","results":[{"id":1,"title":"T","url":"https://a.fr","snippet":"x"}]}"#
        #expect(try PerplexityAgentClient.parseSSELine(line) == .sources([PerplexitySource(id: 1, title: "T", url: "https://a.fr")]))
    }

    @Test("SSE : lignes ignorées")
    func ignoresOtherLines() throws {
        #expect(try PerplexityAgentClient.parseSSELine("event: response.completed") == nil)
        #expect(try PerplexityAgentClient.parseSSELine("") == nil)
        #expect(try PerplexityAgentClient.parseSSELine("data: [DONE]") == nil)
        #expect(try PerplexityAgentClient.parseSSELine(#"data: {"type":"response.completed"}"#) == nil)
    }

    @Test("SSE : échec et JSON illisible")
    func parsesFailures() {
        #expect(throws: PerplexityAgentError.generationFailed) {
            try PerplexityAgentClient.parseSSELine(#"data: {"type":"response.failed"}"#)
        }
        #expect(throws: PerplexityAgentError.generationFailed) {
            try PerplexityAgentClient.parseSSELine(#"data: {"type":"error","message":"secret serveur"}"#)
        }
        #expect(throws: PerplexityAgentError.decodingFailed) {
            try PerplexityAgentClient.parseSSELine("data: {pas du json")
        }
    }

    @Test("Réponse non-streaming : texte des messages + sources")
    func decodesResponse() throws {
        let json = Data("""
        {"status":"completed","output":[
          {"type":"search_results","results":[{"id":1,"title":"A","url":"https://a.fr"}]},
          {"type":"reasoning","content":"autre forme"},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Salut [1]","annotations":[]}]}
        ]}
        """.utf8)
        let response = try PerplexityAgentClient.decodeResponse(from: json)
        #expect(response.text == "Salut [1]")
        #expect(response.sources == [PerplexitySource(id: 1, title: "A", url: "https://a.fr")])
    }

    @Test("Réponse : statut failed, vide ou illisible → erreurs")
    func decodeFailures() {
        #expect(throws: PerplexityAgentError.generationFailed) {
            try PerplexityAgentClient.decodeResponse(from: Data(#"{"status":"failed","output":[]}"#.utf8))
        }
        #expect(throws: PerplexityAgentError.decodingFailed) {
            try PerplexityAgentClient.decodeResponse(from: Data(#"{"status":"completed","output":[]}"#.utf8))
        }
        #expect(throws: PerplexityAgentError.decodingFailed) {
            try PerplexityAgentClient.decodeResponse(from: Data("<html>".utf8))
        }
    }
}

@MainActor
@Suite("PerplexityAgentProvider")
struct PerplexityAgentProviderTests {
    private func provider(
        key: String? = "k",
        client: MockPerplexityClient = MockPerplexityClient(),
        keyError: (any Error)? = nil
    ) -> PerplexityAgentProvider {
        PerplexityAgentProvider(
            baseURL: pplxBase, model: "fast",
            keyStore: PplxKeyStore(storedKey: key, readError: keyError), client: client
        )
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await item in stream { out.append(item) }
        return out
    }

    @Test("Sans clé : missingAPIKey, en generate comme en stream")
    func missingKey() async {
        await #expect(throws: PerplexityAgentError.missingAPIKey) { try await provider(key: nil).generate(prompt: "x") }
        await #expect(throws: PerplexityAgentError.missingAPIKey) { _ = try await collect(provider(key: "").streamGenerate(prompt: "x")) }
    }

    @Test("Erreur Keychain → message fixe")
    func keychainError() async {
        await #expect(throws: PerplexityAgentError.keychainUnavailable) {
            try await provider(keyError: PplxStubError()).generate(prompt: "x")
        }
    }

    @Test("generate délègue au client")
    func generateDelegates() async throws {
        #expect(try await provider(client: MockPerplexityClient(generated: "réponse")).generate(prompt: "x") == "réponse")
    }

    @Test("Le flux émet des instantanés cumulatifs et remonte les sources")
    func streamIsCumulative() async throws {
        let src = PerplexitySource(id: 1, title: nil, url: "https://a.fr")
        let client = MockPerplexityClient(events: [.sources([src]), .textDelta("Bon"), .textDelta("jour")])
        let received = SourceBox()
        let p = PerplexityAgentProvider(
            baseURL: pplxBase, model: "fast", keyStore: PplxKeyStore(storedKey: "k"), client: client,
            onSources: { received.set($0) }
        )
        #expect(try await collect(p.streamGenerate(prompt: "x")) == ["Bon", "Bonjour"])
        #expect(received.value == [src])
    }

    @Test("Une erreur du flux est propagée, l'annulation reste CancellationError")
    func streamPropagatesErrors() async {
        await #expect(throws: PerplexityAgentError.rateLimited) {
            _ = try await collect(provider(client: MockPerplexityClient(streamError: PerplexityAgentError.rateLimited)).streamGenerate(prompt: "x"))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await collect(provider(client: MockPerplexityClient(streamError: CancellationError())).streamGenerate(prompt: "x"))
        }
    }

    @Test("Le résolveur route Perplexity vers l'Agent API, les autres vers OpenAI-compatible")
    func resolverRouting() throws {
        let store = PplxKeyStore(storedKey: "k")
        let pplx = CloudProviderSelectionResolver.makeProvider(
            for: CloudProviderSelection(providerID: "perplexity", model: "high"), customPresets: [], keyStore: store
        )
        let agent = try #require(pplx as? PerplexityAgentProvider)
        #expect(agent.model == "high")

        let groq = CloudProviderSelectionResolver.makeProvider(
            for: CloudProviderSelection(providerID: "groq", model: "m"), customPresets: [], keyStore: store
        )
        #expect(groq is OpenAICompatibleProvider)
    }
}

private nonisolated final class SourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PerplexitySource] = []
    var value: [PerplexitySource] { lock.withLock { stored } }
    func set(_ value: [PerplexitySource]) { lock.withLock { stored = value } }
}
