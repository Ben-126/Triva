//
//  WebSearchChainTestSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Doublures partagées par `WebSearchChainTests` et `WebSearchChainWiringTests` (RI1b). Noms
// préfixés exprès : d'autres fichiers déclarent des `MockSearXNGClient` ou `MockAPIKeyStore`
// `private`, un homonyme interne rendrait leurs références ambiguës.

/// Source de recherche factice, scénarisée : résultats, erreur, ou attente de l'annulation.
/// Journalise chaque appel (requête, options) sans aucun réseau.
///
/// Conformité à `WebSearchProviding` déclarée en EXTENSION, pas sur l'acteur : avec Xcode 27 /
/// Swift 6.4, un `actor` INTERNE de la cible de tests conforme à un protocole `nonisolated` reçoit
/// un `nonisolated` implicite, que le compilateur refuse ensuite à l'émission du module
/// (« 'nonisolated' modifier cannot be applied to this declaration »). Les `private actor` n'y
/// passent pas, et l'inférence ne regarde que la déclaration principale du type. Autre contournement
/// du projet : classe + `Mutex` (`ScriptedInstanceClient`), mais ses `await` deviennent inutiles.
actor ScriptedWebSearchProvider {
    enum Outcome: Sendable {
        case results([SearXNGSearchResult])
        case failure(any Error & Sendable)
        /// Dort jusqu'à l'annulation de la tâche (lève alors `CancellationError`).
        case waitForCancellation
    }

    nonisolated let kind: WebSearchSourceKind
    private let outcome: Outcome
    private let outcomesByCategory: [WebSearchCategory: Outcome]
    private(set) var calls: [WebSearchOptions] = []
    private(set) var receivedQueries: [String] = []

    init(kind: WebSearchSourceKind, outcome: Outcome, outcomesByCategory: [WebSearchCategory: Outcome] = [:]) {
        self.kind = kind
        self.outcome = outcome
        self.outcomesByCategory = outcomesByCategory
    }

    var callCount: Int { calls.count }
    var categories: [WebSearchCategory] { calls.map(\.category) }
}

extension ScriptedWebSearchProvider: WebSearchProviding {
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        calls.append(options)
        receivedQueries.append(query)
        switch outcomesByCategory[options.category] ?? outcome {
        case .results(let results):
            return SearXNGSearchResponse(results: results, suggestions: [])
        case .failure(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return SearXNGSearchResponse(results: [], suggestions: [])
        }
    }
}

/// Client SearXNG factice pour un vrai `FailoverManager` : réponse fixe ou échec, options journalisées.
/// Conformité en extension : voir `ScriptedWebSearchProvider`.
actor ChainSearXNGClient {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool
    private(set) var receivedOptions: [SearXNGSearchOptions] = []
    private(set) var receivedQueries: [String] = []

    init(results: [SearXNGSearchResult] = [], shouldFail: Bool = false) {
        self.response = SearXNGSearchResponse(results: results, suggestions: [])
        self.shouldFail = shouldFail
    }

    var callCount: Int { receivedOptions.count }
}

extension ChainSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedOptions.append(options)
        receivedQueries.append(query)
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return response
    }
}

/// Provider IA factice : classification (`<user_query>`) = `classification` (vide par défaut :
/// repli sûr du classifieur, recherche web générale sans widget), tout le reste = `answer`.
/// `streamGenerate` : implémentation par défaut du protocole (un seul yield).
final class ChainAIProvider: AIGenerating {
    private let classification: String
    private let answer: String
    private(set) var receivedPrompts: [String] = []

    init(classification: String = "", answer: String = "Réponse factice.") {
        self.classification = classification
        self.answer = answer
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        return prompt.contains("<user_query>") ? classification : answer
    }
}

/// Trousseau en mémoire : jamais le vrai trousseau de l'appareil depuis un test.
final class ChainKeyStore: APIKeyStoring, @unchecked Sendable {
    var items: [String: String]
    var failOnRead = false

    init(items: [String: String] = [:]) {
        self.items = items
    }

    func apiKey(account: String) throws -> String? {
        if failOnRead { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        return items[account]
    }

    func save(apiKey: String, account: String) throws {
        items[account] = apiKey
    }

    func deleteAPIKey(account: String) throws {
        items[account] = nil
    }
}

/// Détection de langue factice : table texte -> langue, `otherwise` pour le reste. Les tests ne
/// dépendent ainsi ni du modèle système ni de la langue du Mac.
struct StubLanguageIdentifier: TextLanguageIdentifying {
    var languages: [String: String] = [:]
    var otherwise: String?

    func dominantLanguage(of text: String) -> String? {
        languages[text] ?? otherwise
    }
}

/// Réseau coupé : toute requête échoue, sans jamais sortir de l'appareil.
struct ChainOfflineRequester: HTTPDataRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

enum ChainFixtures {
    static let instance = URL(string: "https://searxng.example")!

    static func result(_ title: String, url: String, content: String? = nil) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content ?? "Extrait \(title)",
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    /// Sources ouvertes hors ligne (aucune requête ne sort) et sans pause arXiv de 3 s.
    static func offlineOpenSources() -> OpenSourceSearchChain {
        OpenSourceSearchChain(requester: ChainOfflineRequester(), arXivSpacer: ArXivRequestSpacer(interval: .zero))
    }

    /// Sélection cloud Claude, fournisseur qui sait chercher sur le web.
    @MainActor
    static var claudeSelection: CloudProviderSelection {
        CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-sonnet-5")
    }

    /// Clés de recherche personnelles en mémoire (`SearchKeyStore` sur un faux trousseau).
    @MainActor
    static func searchKeys(brave: String? = nil, tavily: String? = nil, failOnRead: Bool = false) -> SearchKeyStore {
        let keychain = ChainKeyStore()
        if let brave { keychain.items[BYOKSearchSource.brave.keyAccount] = brave }
        if let tavily { keychain.items[BYOKSearchSource.tavily.keyAccount] = tavily }
        keychain.failOnRead = failOnRead
        return SearchKeyStore(keyStore: keychain, requester: ChainOfflineRequester())
    }

    /// Poll coopératif : `Task.sleep` (1 ms), JAMAIS `Task.yield()` (voir `waitUntil` de
    /// `ChatViewModelTests`, bug du 2026-09-15 sous isolation MainActor par défaut).
    static func waitUntil(
        _ timeoutMessage: String,
        maxAttempts: Int = 2_000,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<maxAttempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timeout en attendant : \(timeoutMessage)")
    }
}
