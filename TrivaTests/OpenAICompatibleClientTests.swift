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

    @Test("Extrait le message d'erreur de l'API quand le corps en contient un")
    func decodesAPIErrorMessage() {
        let json = Data("""
        {"error":{"message":"Invalid API key"}}
        """.utf8)

        #expect(OpenAICompatibleClient.decodeErrorMessage(from: json) == "Invalid API key")
    }

    @Test("Renvoie nil si le corps ne contient pas de message d'erreur exploitable")
    func decodeErrorMessageReturnsNilWithoutErrorField() {
        let json = Data("{}".utf8)

        #expect(OpenAICompatibleClient.decodeErrorMessage(from: json) == nil)
    }
}

extension DecodedRequestBody.Message: Equatable {}
