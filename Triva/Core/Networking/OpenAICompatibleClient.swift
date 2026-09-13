//
//  OpenAICompatibleClient.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

/// Abstraction du client HTTP compatible OpenAI, pour permettre le mock dans
/// les tests de `OpenAICompatibleProvider` sans appel réseau réel.
protocol OpenAICompatibleRequesting: Sendable {
    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String
}

enum OpenAICompatibleClientError: Error, Sendable, Equatable {
    case requestFailed(statusCode: Int)
    case transportError
    case decodingFailed
    case apiError(message: String)
}

private struct ChatCompletionRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable {
            let content: String
        }

        let message: Msg
    }

    let choices: [Choice]
}

private struct ChatCompletionErrorBody: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

/// Client HTTP réel vers n'importe quel fournisseur cloud BYOK compatible
/// OpenAI (0.6 élargi : Groq, OpenRouter, Mistral, DeepSeek, etc., ainsi que
/// les entrées "Personnalisé" — voir `CloudProviderCatalog`). Un seul client
/// générique plutôt qu'un provider par fournisseur, puisqu'ils partagent
/// tous le même contrat `POST {baseURL}/chat/completions`.
struct OpenAICompatibleClient: OpenAICompatibleRequesting {
    private let urlSession: URLSession
    private let timeoutInterval: TimeInterval

    init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 30) {
        self.urlSession = urlSession
        self.timeoutInterval = timeoutInterval
    }

    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String {
        let url = CloudProviderCatalog.chatCompletionsURL(baseURL: baseURL)
        let request = try Self.buildRequest(
            url: url,
            apiKey: apiKey,
            model: model,
            prompt: prompt,
            timeoutInterval: timeoutInterval
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            // Annulation : ne pas la maquiller en refus de clé côté fournisseur.
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw urlError
        } catch {
            throw OpenAICompatibleClientError.transportError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.transportError
        }
        guard httpResponse.statusCode == 200 else {
            if let apiMessage = Self.decodeErrorMessage(from: data) {
                throw OpenAICompatibleClientError.apiError(message: apiMessage)
            }
            throw OpenAICompatibleClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return try Self.decodeContent(from: data)
    }

    /// Logique pure isolée du réseau réel, pour rester testable sans mock HTTP.
    static func buildRequest(
        url: URL,
        apiKey: String,
        model: String,
        prompt: String,
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequestBody(model: model, messages: [.init(role: "user", content: prompt)])
        )
        return request
    }

    static func decodeContent(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponseBody.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw OpenAICompatibleClientError.decodingFailed
        }
        return content
    }

    static func decodeErrorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(ChatCompletionErrorBody.self, from: data).error.message
    }
}
