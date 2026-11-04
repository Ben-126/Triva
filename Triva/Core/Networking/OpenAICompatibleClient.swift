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
    /// Échec dont le corps est l'enveloppe `{"error":{…}}`, le cas le plus fréquent (OpenAI, Groq,
    /// OpenRouter, DeepSeek, Mistral). `error.message` n'est JAMAIS gardé : un serveur
    /// « Personnalisé » peut y renvoyer l'en-tête `Authorization: Bearer <clé>`.
    case apiError(statusCode: Int, code: OpenAICompatibleAPIErrorCode?)
}

/// Codes d'erreur reconnus dans `error.code` ou `error.type` : un enum FERMÉ, aucun texte du
/// serveur n'en sort. Ils précisent ce que le statut seul ne dit pas : le contexte dépassé arrive
/// en 400, et le crédit épuisé se confond avec une simple limite de débit en 429.
nonisolated enum OpenAICompatibleAPIErrorCode: String, Sendable, Equatable {
    case contextLengthExceeded = "context_length_exceeded"
    case invalidAPIKey = "invalid_api_key"
    case insufficientQuota = "insufficient_quota"
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
    /// `message` n'est volontairement pas décodé (voir `OpenAICompatibleClientError.apiError`).
    /// `try?` champ par champ : OpenRouter envoie un `code` NUMÉRIQUE, qui ne doit pas faire
    /// perdre l'enveloppe, ni l'autre champ.
    struct APIError: Decodable {
        let code: String?
        let type: String?

        private enum CodingKeys: String, CodingKey {
            case code, type
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
        }
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
            throw Self.failure(statusCode: httpResponse.statusCode, body: data)
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

    /// Erreur d'une réponse d'échec : le statut toujours, le code s'il est reconnu, rien d'autre
    /// du corps. Logique pure, testable sans réseau.
    static func failure(statusCode: Int, body: Data) -> OpenAICompatibleClientError {
        guard let error = try? JSONDecoder().decode(ChatCompletionErrorBody.self, from: body).error else {
            return .requestFailed(statusCode: statusCode)
        }
        let code = [error.code, error.type].lazy.compactMap { $0 }.compactMap(OpenAICompatibleAPIErrorCode.init(rawValue:)).first
        return .apiError(statusCode: statusCode, code: code)
    }
}
