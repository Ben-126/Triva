//
//  OpenAICompatibleClientTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Reflète la forme du corps envoyé par `OpenAICompatibleClient.buildRequest`,
/// pour vérifier son contenu sans exposer le type interne du client.
private struct DecodedRequestBody: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

@MainActor
@Suite("OpenAICompatibleClient")
struct OpenAICompatibleClientTests {
    @Test("Construit une requête POST avec l'en-tête d'auth, le Content-Type et le bon corps JSON")
    func buildsWellFormedRequest() throws {
        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

        let request = try OpenAICompatibleClient.buildRequest(
            url: url,
            apiKey: "sk-test",
            model: "llama-3.3-70b-versatile",
            prompt: "Bonjour",
            timeoutInterval: 30
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(DecodedRequestBody.self, from: body)
        #expect(decoded.model == "llama-3.3-70b-versatile")
        #expect(decoded.messages == [DecodedRequestBody.Message(role: "user", content: "Bonjour")])
    }

    @Test("Décode le contenu d'une réponse valide")
    func decodesValidResponse() throws {
        let json = Data("""
        {"choices":[{"message":{"content":"Bonjour !"}}]}
        """.utf8)

        #expect(try OpenAICompatibleClient.decodeContent(from: json) == "Bonjour !")
    }

    @Test("Échoue avec decodingFailed quand la réponse n'a pas de choices exploitables")
    func failsOnMalformedResponse() {
        let json = Data("{}".utf8)

        #expect(throws: OpenAICompatibleClientError.decodingFailed) {
            _ = try OpenAICompatibleClient.decodeContent(from: json)
        }
    }

    @Test("Échoue avec decodingFailed sur un JSON invalide")
    func failsOnInvalidJSON() {
        let json = Data("not json".utf8)

        #expect(throws: OpenAICompatibleClientError.decodingFailed) {
            _ = try OpenAICompatibleClient.decodeContent(from: json)
        }
    }

    @Test("Corps d'erreur JSON : le statut est toujours gardé, le message du serveur jamais")
    func apiErrorKeepsTheStatusAndDropsTheMessage() {
        let json = Data("""
        {"error":{"message":"Invalid header: Bearer sk-SECRET-42"}}
        """.utf8)

        let failure = OpenAICompatibleClient.failure(statusCode: 401, body: json)

        #expect(failure == .apiError(statusCode: 401, code: nil))
        #expect(!String(describing: failure).contains("SECRET"))
    }

    @Test("error.code ou error.type reconnu : enum fermé", arguments: [
        (#"{"error":{"message":"m","type":"invalid_request_error","code":"context_length_exceeded"}}"#, OpenAICompatibleAPIErrorCode.contextLengthExceeded),
        (#"{"error":{"message":"m","type":"invalid_request_error","code":"invalid_api_key"}}"#, .invalidAPIKey),
        (#"{"error":{"message":"m","type":"insufficient_quota","code":null}}"#, .insufficientQuota),
        (#"{"error":{"message":"m","type":"insufficient_quota","code":402}}"#, .insufficientQuota),
    ])
    func recognizedCodes(body: String, expected: OpenAICompatibleAPIErrorCode) {
        #expect(OpenAICompatibleClient.failure(statusCode: 400, body: Data(body.utf8)) == .apiError(statusCode: 400, code: expected))
    }

    @Test("Code inconnu, ou numérique (OpenRouter) : enveloppe gardée, sans code")
    func unknownCodesAreDropped() {
        let unknown = Data(#"{"error":{"message":"m","type":"weird","code":"Bearer sk-SECRET-42"}}"#.utf8)
        let numeric = Data(#"{"error":{"message":"m","code":429}}"#.utf8)

        #expect(OpenAICompatibleClient.failure(statusCode: 400, body: unknown) == .apiError(statusCode: 400, code: nil))
        #expect(OpenAICompatibleClient.failure(statusCode: 429, body: numeric) == .apiError(statusCode: 429, code: nil))
    }

    @Test("Corps sans enveloppe d'erreur : requestFailed", arguments: ["{}", "<html>Bad Gateway</html>", #"{"error":"texte"}"#, ""])
    func bodyWithoutEnvelope(body: String) {
        #expect(OpenAICompatibleClient.failure(statusCode: 502, body: Data(body.utf8)) == .requestFailed(statusCode: 502))
    }
}

extension DecodedRequestBody.Message: Equatable {}
