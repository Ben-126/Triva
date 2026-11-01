//
//  CloudModelListService.swift
//  Triva
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation
import CryptoKit

/// Un modèle proposé dans le menu déroulant de `CloudProviderModelPickerView`.
/// `nonisolated` : donnée pure, décodée et comparée hors du main actor.
nonisolated struct CloudModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

/// D'où vient la liste des modèles d'un fournisseur. Chaque fournisseur
/// expose un format différent — voir `CloudModelListService.source(...)`.
nonisolated enum CloudModelListSource: Sendable, Equatable {
    /// `GET {baseURL}/models`, `Authorization: Bearer`, réponse
    /// `{ "data": [ { "id": … } ] }` (contrat OpenAI « List models »).
    case openAICompatible(baseURL: URL)
    /// `GET https://api.anthropic.com/v1/models`, `x-api-key` +
    /// `anthropic-version`, réponse `{ "data": [ { "id", "display_name" } ] }`.
    case anthropic
    /// API native Gemini `GET …/v1beta/models` : seule à indiquer, par
    /// `supportedGenerationMethods`, quels modèles savent générer du texte.
    case gemini
    /// Fournisseur sans endpoint de liste utilisable : liste fixe, aucun appel.
    case staticList([CloudModelOption])
}

/// Erreurs de récupération de la liste. Aucun cas ne porte de chaîne venue
/// du réseau ou de l'appelant : la clé ne peut donc jamais finir dans un
/// message, un log ou une description d'erreur.
nonisolated enum CloudModelListError: Error, Sendable, Equatable {
    case invalidKey
    case forbidden
    case rateLimited
    case serverUnavailable
    case unexpectedStatus(Int)
    case timeout
    case network
    /// Endpoint de liste absent chez ce fournisseur (404, 405, 410, 501).
    case listUnavailable
    /// Réponse reçue mais au format inconnu.
    case decoding

    /// Vrai quand réessayer ne changera rien : la liste ne PEUT PAS être
    /// obtenue (typiquement un fournisseur personnalisé sans `/models`). La
    /// vue propose alors la saisie manuelle au lieu de « Réessayer ».
    var meansListUnavailable: Bool {
        self == .listUnavailable || self == .decoding
    }

    /// Message fixe en français, affiché tel quel sous le menu.
    var message: String {
        switch self {
        case .invalidKey: "Clé refusée par le fournisseur. Vérifie-la dans les réglages des clés."
        case .forbidden: "Cette clé n'a pas accès à la liste des modèles."
        case .rateLimited: "Trop de requêtes pour le moment. Réessaie dans un instant."
        case .serverUnavailable: "Le fournisseur ne répond pas correctement pour le moment."
        case .unexpectedStatus(let code): "Réponse inattendue du fournisseur (code \(code))."
        case .timeout: "Le fournisseur met trop de temps à répondre."
        case .network: "Impossible de joindre le fournisseur. Vérifie ta connexion."
        case .listUnavailable: "Ce fournisseur ne publie pas sa liste de modèles. Saisis le nom exact du modèle."
        case .decoding: "La liste de modèles de ce fournisseur est dans un format inconnu. Saisis le nom exact du modèle."
        }
    }
}

/// Exécute une requête HTTP complète. `URLFetching` ne prend qu'une URL,
/// sans en-têtes : impossible d'y passer `Authorization` ou `x-api-key`,
/// d'où cette abstraction dédiée (même style DI, mockable sans réseau).
nonisolated protocol HTTPDataRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionDataRequester: HTTPDataRequesting {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await urlSession.data(for: request)
    }
}

/// Cache en mémoire des listes déjà récupérées, par (fournisseur, empreinte
/// SHA-256 de la clé) : changer de clé invalide naturellement l'entrée. La
/// clé elle-même n'est jamais conservée ici — elle reste dans le Keychain.
actor CloudModelListCache {
    static let shared = CloudModelListCache()

    private struct Entry {
        let models: [CloudModelOption]
        let storedAt: Date
    }

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 600) {
        self.lifetime = lifetime
    }

    func models(for cacheKey: String, now: Date = Date()) -> [CloudModelOption]? {
        guard let entry = entries[cacheKey], now.timeIntervalSince(entry.storedAt) < lifetime else {
            return nil
        }
        return entry.models
    }

    func store(_ models: [CloudModelOption], for cacheKey: String, now: Date = Date()) {
        entries[cacheKey] = Entry(models: models, storedAt: now)
    }
}

/// Récupère, depuis l'appareil et avec la clé de l'utilisateur, la liste des
/// modèles réellement disponibles chez son fournisseur cloud — aucun serveur
/// intermédiaire (règle « zéro backend »).
///
/// CONCURRENCE : `@concurrent` sur `models(...)` — sous
/// `NonisolatedNonsendingByDefault`, sans lui, le décodage d'une liste
/// OpenRouter (plusieurs centaines d'entrées) tournerait sur le main actor
/// du view model appelant.
nonisolated struct CloudModelListService: Sendable {
    /// Délai d'inactivité de la requête : un menu qui charge plus longtemps
    /// n'aide personne, « Réessayer » reste disponible.
    static let requestTimeout: TimeInterval = 10

    /// Valeur d'`anthropic-version` envoyée par `ClaudeClient` (package
    /// ClaudeForFoundationModels, `Configuration.version`) : même contrat.
    static let anthropicVersion = "2023-06-01"
    static let anthropicModelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
    static let geminiModelsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!

    /// Niveaux d'effort de l'Agent API Perplexity (docs.perplexity.ai/docs/agent-api/effort.md,
    /// consultée le 2026-10-28) : le chat Perplexity passe par `POST /v1/agent`, Sonar Chat
    /// Completions étant arrêté depuis le 2026-09-27. `GET /v1/models` liste des modèles
    /// `fournisseur/modèle`, pas les niveaux d'effort : liste fixe.
    static let perplexityModels: [CloudModelOption] = [
        CloudModelOption(id: "fast", displayName: "fast"),
        CloudModelOption(id: "low", displayName: "low"),
        CloudModelOption(id: "medium", displayName: "medium"),
        CloudModelOption(id: "high", displayName: "high"),
        CloudModelOption(id: "xhigh", displayName: "xhigh"),
    ]

    /// Fragments d'id qui désignent sans ambiguïté un modèle qui ne génère pas
    /// de texte (embeddings, audio, image, modération, OCR, classifieurs de
    /// sécurité). Liste volontairement courte : dans le doute, on garde.
    static let nonChatIDFragments = [
        "embed", "whisper", "tts", "dall-e", "moderation", "transcribe",
        "realtime", "audio", "image", "sora", "rerank", "ocr", "guard",
    ]

    private let requester: any HTTPDataRequesting
    private let cache: CloudModelListCache

    init(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        cache: CloudModelListCache = .shared
    ) {
        self.requester = requester
        self.cache = cache
    }

    /// Source de la liste pour `providerID` ; `nil` si le fournisseur est
    /// inconnu (ni Claude, ni catalogue, ni personnalisé). `@MainActor` :
    /// `CloudProviderCatalog.presets` est isolé au main actor (isolation par
    /// défaut du projet), et le seul appelant est le view model.
    @MainActor
    static func source(forProviderID providerID: String, customPresets: [CloudProviderPreset]) -> CloudModelListSource? {
        switch providerID {
        case CloudProviderSelectionResolver.claudeProviderID: return .anthropic
        case "gemini": return .gemini
        case "perplexity": return .staticList(perplexityModels)
        default:
            guard let preset = (CloudProviderCatalog.presets + customPresets).first(where: { $0.id == providerID }) else {
                return nil
            }
            return .openAICompatible(baseURL: preset.baseURL)
        }
    }

    @concurrent
    func models(
        providerID: String,
        source: CloudModelListSource,
        apiKey: String,
        forceRefresh: Bool = false
    ) async throws -> [CloudModelOption] {
        if case .staticList(let models) = source { return models }

        let cacheKey = Self.cacheKey(providerID: providerID, apiKey: apiKey)
        if !forceRefresh, let cached = await cache.models(for: cacheKey) {
            return cached
        }

        let data = try await perform(Self.request(for: source, apiKey: apiKey))
        let models = try Self.parse(data, source: source)
        await cache.store(models, for: cacheKey)
        return models
    }

    // MARK: - Requête

    static func request(for source: CloudModelListSource, apiKey: String) -> URLRequest {
        let url: URL
        switch source {
        case .openAICompatible(let baseURL): url = baseURL.appendingPathComponent("models")
        case .anthropic: url = anthropicModelsURL
        case .gemini: url = geminiModelsURL
        case .staticList: url = URL(string: "about:blank")!
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch source {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .gemini:
            // En-tête plutôt que `?key=` : la clé ne figure ainsi jamais dans
            // une URL (journaux système, descriptions d'erreur `URLError`).
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .staticList:
            break
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requester.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CloudModelListError.timeout
            default: throw CloudModelListError.network
            }
        } catch {
            throw CloudModelListError.network
        }

        guard let http = response as? HTTPURLResponse else { throw CloudModelListError.network }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw CloudModelListError.invalidKey
        case 403: throw CloudModelListError.forbidden
        case 429: throw CloudModelListError.rateLimited
        case 404, 405, 410, 501: throw CloudModelListError.listUnavailable
        case 500..<600: throw CloudModelListError.serverUnavailable
        default: throw CloudModelListError.unexpectedStatus(http.statusCode)
        }
    }

    // MARK: - Décodage

    private struct OpenAIListBody: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct AnthropicListBody: Decodable {
        struct Model: Decodable {
            let id: String
            let display_name: String?
        }
        let data: [Model]
    }

    private struct GeminiListBody: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]?
    }

    /// Décode, filtre, dédoublonne et trie. Ordre de l'API conservé pour
    /// Anthropic (du plus récent au plus ancien, documenté) ; tri
    /// alphabétique naturel ailleurs, où l'ordre renvoyé n'a pas de sens.
    static func parse(_ data: Data, source: CloudModelListSource) throws -> [CloudModelOption] {
        let decoder = JSONDecoder()
        do {
            switch source {
            case .openAICompatible:
                let body = try decoder.decode(OpenAIListBody.self, from: data)
                let options = body.data
                    .map { CloudModelOption(id: $0.id, displayName: $0.id) }
                    .filter { isChatModel(id: $0.id) }
                return sortedNaturally(deduplicated(options))
            case .anthropic:
                let body = try decoder.decode(AnthropicListBody.self, from: data)
                let options = body.data.map {
                    CloudModelOption(id: $0.id, displayName: nonEmpty($0.display_name) ?? $0.id)
                }
                return deduplicated(options)
            case .gemini:
                let body = try decoder.decode(GeminiListBody.self, from: data)
                let options = (body.models ?? [])
                    .filter { $0.supportedGenerationMethods?.contains("generateContent") == true }
                    .map { model -> CloudModelOption in
                        // `models/gemini-2.5-flash` → `gemini-2.5-flash`, la
                        // forme attendue par l'endpoint compatible OpenAI.
                        let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst("models/".count)) : model.name
                        return CloudModelOption(id: id, displayName: nonEmpty(model.displayName) ?? id)
                    }
                    .filter { isChatModel(id: $0.id) }
                return sortedNaturally(deduplicated(options))
            case .staticList(let models):
                return models
            }
        } catch {
            throw CloudModelListError.decoding
        }
    }

    static func isChatModel(id: String) -> Bool {
        let lowered = id.lowercased()
        return !nonChatIDFragments.contains { lowered.contains($0) }
    }

    private static func deduplicated(_ options: [CloudModelOption]) -> [CloudModelOption] {
        var seen = Set<String>()
        return options.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    private static func sortedNaturally(_ options: [CloudModelOption]) -> [CloudModelOption] {
        options.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Cache

    /// Empreinte non réversible : la clé n'est jamais une clé de dictionnaire.
    static func cacheKey(providerID: String, apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        let fingerprint = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(providerID)|\(fingerprint)"
    }
}
