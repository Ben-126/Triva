//
//  PerplexityAgentClient.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

// Sources (docs officielles Perplexity, consultées le 2026-10-28) :
// - https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview.md
//   « Sonar Chat Completions support ended on September 27, 2026 » : les requêtes
//   synchrones et streaming sont « reformulées » vers l'Agent API, déploiement progressif
//   par modèle, sans garantie. Les nouveaux usages doivent viser l'Agent API.
// - https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/how-to.md
//   `POST /v1/agent`, corps `{ "effort": …, "input": …, "stream": … }` ; réponse = tableau
//   `output` typé (`search_results`, `message` → `content[].output_text.text`).
// - https://docs.perplexity.ai/docs/agent-api/output-control.md et
//   https://docs.perplexity.ai/docs/cookbook/articles/streaming-citations/README.md
//   Streaming SSE typé : `response.output_text.delta` (champ `delta`),
//   `response.reasoning.search_results` (champ `results`), `response.completed`.
// - https://docs.perplexity.ai/docs/agent-api/effort.md
//   Niveaux d'effort `fast` / `low` / `medium` / `high` / `xhigh` (le niveau `fast` active
//   la recherche web par défaut). Pas d'endpoint de liste pour les niveaux : liste statique.

/// Erreurs du client Perplexity. Les messages sont FIXES : jamais de corps d'erreur serveur
/// relayé à l'utilisateur ni dans les logs.
nonisolated enum PerplexityAgentError: Error, Sendable, Equatable, LocalizedError {
    /// Aucune clé API Perplexity en Keychain.
    case missingAPIKey
    case keychainUnavailable
    /// 401 / 403.
    case invalidKey
    /// 429.
    case rateLimited
    /// Autre 4xx.
    case requestRejected
    /// 5xx.
    case serverError
    case transportError
    case decodingFailed
    /// Événement `response.failed` / `error` ou statut `failed` dans la réponse.
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Aucune clé API Perplexity n'est enregistrée."
        case .keychainUnavailable: "Impossible de lire la clé API Perplexity dans le trousseau."
        case .invalidKey: "Perplexity a refusé la clé API. Vérifie-la dans les réglages."
        case .rateLimited: "Perplexity limite temporairement les requêtes. Réessaie dans un instant."
        case .requestRejected: "Perplexity a refusé la requête."
        case .serverError: "Perplexity est momentanément indisponible. Réessaie plus tard."
        case .transportError: "Connexion à Perplexity impossible. Vérifie ta connexion."
        case .decodingFailed: "La réponse de Perplexity est illisible."
        case .generationFailed: "Perplexity n'a pas pu terminer la réponse."
        }
    }
}

/// Source renvoyée par la recherche web de Perplexity. Les marqueurs `[n]` du texte généré
/// pointent vers `id`. Non perdue : voir `PerplexityStreamEvent.sources`.
nonisolated struct PerplexitySource: Sendable, Equatable, Decodable {
    let id: Int?
    let title: String?
    let url: String
}

nonisolated enum PerplexityStreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// Un événement par recherche : à accumuler (les `id` partagent un même espace).
    case sources([PerplexitySource])
}

nonisolated struct PerplexityAgentResponse: Sendable, Equatable {
    let text: String
    let sources: [PerplexitySource]
}

/// Étend le contrat « génération simple » (utilisé aussi par le validateur de clé) avec le
/// streaming d'événements typés.
protocol PerplexityAgentRequesting: OpenAICompatibleRequesting {
    func stream(baseURL: URL, apiKey: String, model: String, prompt: String) -> AsyncThrowingStream<PerplexityStreamEvent, Error>
}

/// Client minimal de l'Agent API Perplexity (`POST {baseURL}/v1/agent`). La clé ne voyage que
/// dans l'en-tête `Authorization`. L'annulation est propagée telle quelle (`CancellationError`).
nonisolated struct PerplexityAgentClient: PerplexityAgentRequesting {
    static let host = "api.perplexity.ai"
    static let defaultEffort = "fast"

    /// Correspondance documentée Sonar → niveau d'effort (page « Migrate from Sonar »), pour
    /// les sélections enregistrées avant la migration.
    static let legacySonarEfforts: [String: String] = [
        "sonar": "fast",
        "sonar-pro": "fast",
        "sonar-reasoning-pro": "low",
        "sonar-deep-research": "high",
    ]

    private let urlSession: URLSession
    private let timeoutInterval: TimeInterval

    init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 90) {
        self.urlSession = urlSession
        self.timeoutInterval = timeoutInterval
    }

    /// Vrai pour le preset Perplexity du catalogue (et toute entrée personnalisée qui pointe
    /// vers le même hôte).
    static func handles(baseURL: URL) -> Bool {
        baseURL.host?.lowercased() == host
    }

    /// Le « modèle » choisi dans Triva est un niveau d'effort ; les anciens ids Sonar sont
    /// convertis, tout le reste (y compris `fast@2026-10-16.0`) est transmis tel quel.
    static func effort(forModel model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultEffort }
        return legacySonarEfforts[trimmed.lowercased()] ?? trimmed
    }

    static func agentURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent("agent")
    }

    // MARK: - Requêtes

    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String {
        let request = try Self.buildRequest(
            baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt,
            stream: false, timeoutInterval: timeoutInterval
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        try Self.validate(response)
        return try Self.decodeResponse(from: data).text
    }

    func stream(baseURL: URL, apiKey: String, model: String, prompt: String) -> AsyncThrowingStream<PerplexityStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.buildRequest(
                        baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt,
                        stream: true, timeoutInterval: timeoutInterval
                    )
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    try Self.validate(response)
                    for try await line in bytes.lines {
                        if let event = try Self.parseSSELine(line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Logique pure (testable sans réseau)

    /// Décision de Ben (2026-10-28) : même expérience qu'avec OpenAI, Claude… Perplexity rédige
    /// uniquement à partir des sources trouvées par Triva (déjà dans `input`), sans sa propre
    /// recherche web : ses marqueurs `[n]` pointent ainsi vers les sources affichées, et
    /// l'utilisateur ne paie pas de recherche en plus. `tool_choice: "none"` est le champ
    /// documenté de `POST /v1/agent` (https://docs.perplexity.ai/api-reference/agent-post.md,
    /// consulté le 2026-10-28) ; omettre `tools` ne suffit pas, car `effort` réactive ses outils.
    static let toolChoice = "none"

    private struct RequestBody: Encodable {
        let effort: String
        let input: String
        let stream: Bool
        let toolChoice: String

        enum CodingKeys: String, CodingKey {
            case effort, input, stream
            case toolChoice = "tool_choice"
        }
    }

    static func buildRequest(
        baseURL: URL,
        apiKey: String,
        model: String,
        prompt: String,
        stream: Bool,
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: agentURL(baseURL: baseURL), timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(effort: effort(forModel: model), input: prompt, stream: stream, toolChoice: toolChoice)
        )
        return request
    }

    static func error(forStatusCode statusCode: Int) -> PerplexityAgentError? {
        switch statusCode {
        case 200..<300: nil
        case 401, 403: .invalidKey
        case 429: .rateLimited
        case 500...: .serverError
        default: .requestRejected
        }
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PerplexityAgentError.transportError }
        if let error = error(forStatusCode: http.statusCode) { throw error }
    }

    /// L'annulation reste une annulation ; une erreur déjà typée est conservée ; le reste est
    /// un problème de transport (le détail système n'est jamais affiché).
    static func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        if error is PerplexityAgentError { return error }
        return PerplexityAgentError.transportError
    }

    /// Traite une ligne SSE. Seules les lignes `data:` comptent ; `nil` pour tout événement
    /// sans intérêt (ou `[DONE]`). `response.failed` / `error` lèvent `generationFailed`.
    static func parseSSELine(_ line: String) throws -> PerplexityStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let envelope = try? JSONDecoder().decode(StreamEnvelope.self, from: Data(payload.utf8)) else {
            throw PerplexityAgentError.decodingFailed
        }
        switch envelope.type {
        case "response.output_text.delta":
            guard let delta = envelope.delta else { return nil }
            return .textDelta(delta)
        case "response.reasoning.search_results":
            guard let results = envelope.results, !results.isEmpty else { return nil }
            return .sources(results)
        case "response.failed", "error":
            throw PerplexityAgentError.generationFailed
        default:
            return nil
        }
    }

    private struct StreamEnvelope: Decodable {
        let type: String
        let delta: String?
        let results: [PerplexitySource]?
    }

    /// Réponse non-streaming : texte des items `message` + sources des items `search_results`.
    static func decodeResponse(from data: Data) throws -> PerplexityAgentResponse {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw PerplexityAgentError.decodingFailed
        }
        if body.status == "failed" || body.status == "cancelled" { throw PerplexityAgentError.generationFailed }
        var text = ""
        var sources: [PerplexitySource] = []
        for item in body.output {
            switch item.type {
            case "message":
                for part in item.content where part.type == "output_text" {
                    text += part.text ?? ""
                }
            case "search_results":
                sources += item.results
            default:
                break
            }
        }
        guard !text.isEmpty else { throw PerplexityAgentError.decodingFailed }
        return PerplexityAgentResponse(text: text, sources: sources)
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable {
            struct Part: Decodable {
                let type: String?
                let text: String?
            }

            let type: String
            let content: [Part]
            let results: [PerplexitySource]

            private enum CodingKeys: String, CodingKey { case type, content, results }

            // Tolérant : les items d'autres types (outils, raisonnement) ont des formes variées.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = (try? container.decode(String.self, forKey: .type)) ?? ""
                content = (try? container.decode([Part].self, forKey: .content)) ?? []
                results = (try? container.decode([PerplexitySource].self, forKey: .results)) ?? []
            }
        }

        let status: String?
        let output: [Item]
    }
}

/// Choisit le client de chat adapté à un `baseURL` : l'Agent API pour Perplexity, le client
/// OpenAI-compatible pour tout le reste. Évite de toucher aux appelants (réglages, validateur).
enum CloudChatClientFactory {
    static func client(forBaseURL baseURL: URL) -> any OpenAICompatibleRequesting {
        PerplexityAgentClient.handles(baseURL: baseURL) ? PerplexityAgentClient() : OpenAICompatibleClient()
    }
}
