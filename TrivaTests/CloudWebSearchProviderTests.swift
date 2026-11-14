//
//  CloudWebSearchProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 28/10/2026.
//

import Testing
import Foundation
@testable import Triva

// Aucun appel réseau réel : tout passe par `BYOKTestRequester` (défini dans
// `SearchKeyProvidersTests.swift`), qui enregistre les requêtes et renvoie un corps fixé.

// MARK: - Fixtures (formats documentés au 2026-10-28)

private enum CloudSearchFixtures {
    /// `POST https://api.perplexity.ai/search` : `results[]` avec `title`, `url`, `snippet`.
    static let perplexity = """
    {
      "results": [
        {
          "title": "Swift Concurrency | Apple Developer Documentation",
          "url": "https://developer.apple.com/documentation/swift/concurrency",
          "snippet": "Perform asynchronous  and parallel\\n operations in your app.",
          "date": "2026-05-10",
          "last_updated": "2026-09-01"
        },
        {
          "title": "Swift Concurrency (doublon)",
          "url": "https://Developer.Apple.com/documentation/swift/concurrency/#intro",
          "snippet": "Doublon : ne doit pas apparaître.",
          "date": null,
          "last_updated": null
        },
        {
          "title": "The Swift Programming Language: Concurrency",
          "url": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/",
          "snippet": "Swift has built-in support for writing asynchronous and parallel code.",
          "date": "2026-08-02",
          "last_updated": null
        },
        { "title": "Lien dangereux", "url": "javascript:alert(1)", "snippet": "ignoré" }
      ],
      "id": "7d8b0c9e-1f2a-4c35-9e0a-0123456789ab",
      "server_time": null
    }
    """

    /// `POST https://api.openai.com/v1/responses` avec `include: ["web_search_call.action.sources"]`.
    static let openAI = """
    {
      "id": "resp_0123",
      "object": "response",
      "status": "completed",
      "model": "gpt-6-luna",
      "output": [
        {
          "type": "web_search_call",
          "id": "ws_0123",
          "status": "completed",
          "action": {
            "type": "search",
            "query": "résultat finale ligue des champions 2026",
            "sources": [
              { "type": "url", "url": "https://www.lemonde.fr/sport/article/2026/05/31/finale.html?utm_source=openai" },
              { "type": "url", "url": "https://example.org/seule-source?id=a%2Bb&utm_source=openai" }
            ]
          }
        },
        {
          "type": "message",
          "id": "msg_0123",
          "status": "completed",
          "role": "assistant",
          "content": [
            {
              "type": "output_text",
              "text": "Le PSG a gagné la finale.",
              "annotations": [
                {
                  "type": "url_citation",
                  "start_index": 0,
                  "end_index": 24,
                  "url": "https://www.lemonde.fr/sport/article/2026/05/31/finale.html?utm_source=openai",
                  "title": "Finale de la Ligue des champions — Le Monde"
                }
              ]
            }
          ]
        }
      ],
      "usage": { "input_tokens": 8100, "output_tokens": 14 }
    }
    """

    /// `POST https://api.anthropic.com/v1/messages` avec l'outil `web_search_20250305`.
    static let anthropic = """
    {
      "id": "msg_a930390d3a",
      "type": "message",
      "role": "assistant",
      "model": "claude-haiku-4-5",
      "content": [
        { "type": "text", "text": "Je cherche la date de naissance de Claude Shannon." },
        {
          "type": "server_tool_use",
          "id": "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE",
          "name": "web_search",
          "input": { "query": "claude shannon birth date" }
        },
        {
          "type": "web_search_tool_result",
          "tool_use_id": "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE",
          "content": [
            {
              "type": "web_search_result",
              "url": "https://en.wikipedia.org/wiki/Claude_Shannon",
              "title": "Claude Shannon - Wikipedia",
              "encrypted_content": "EqgfCioIARgBIiQ3YTAwMjY1Mi1mZjM5LTQ1NGUtODgxNC1kNjNjNTk1ZWI3Y",
              "page_age": "April 30, 2025"
            },
            {
              "type": "web_search_result",
              "url": "https://www.britannica.com/biography/Claude-Shannon",
              "title": "Claude Shannon | Biography | Britannica",
              "encrypted_content": "Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm",
              "page_age": null
            }
          ]
        },
        {
          "type": "text",
          "text": "Claude Shannon est né le 30 avril 1916 à Petoskey, Michigan.",
          "citations": [
            {
              "type": "web_search_result_location",
              "url": "https://en.wikipedia.org/wiki/Claude_Shannon",
              "title": "Claude Shannon - Wikipedia",
              "encrypted_index": "Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm..",
              "cited_text": "Claude Elwood Shannon (April 30, 1916 – February 24, 2001) was an American mathematician..."
            }
          ]
        }
      ],
      "stop_reason": "end_turn",
      "usage": { "input_tokens": 6039, "output_tokens": 93, "server_tool_use": { "web_search_requests": 1 } }
    }
    """

    static func anthropicToolError(code: String) -> String {
        """
        {
          "id": "msg_err", "type": "message", "role": "assistant", "model": "claude-haiku-4-5",
          "content": [
            { "type": "server_tool_use", "id": "srvtoolu_a93jad", "name": "web_search", "input": { "query": "x" } },
            {
              "type": "web_search_tool_result",
              "tool_use_id": "srvtoolu_a93jad",
              "content": { "type": "web_search_tool_result_error", "error_code": "\(code)" }
            }
          ],
          "stop_reason": "end_turn"
        }
        """
    }

}

// MARK: - Aides

private let cloudSearchSecret = "sk-cloud-secret-9f8e7d6c5b4a"

private func cloudProvider(
    _ service: CloudWebSearchService,
    status: Int = 200,
    body: String,
    model: String? = nil
) -> (provider: CloudWebSearchProvider, requester: BYOKTestRequester) {
    let requester = BYOKTestRequester(status: status, body: body)
    let provider = CloudWebSearchProvider(
        service: service, apiKey: cloudSearchSecret, model: model, requester: requester
    )
    return (provider, requester)
}

private func requestBody(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

private func fixture(for service: CloudWebSearchService) -> String {
    switch service {
    case .perplexity: CloudSearchFixtures.perplexity
    case .openAI: CloudSearchFixtures.openAI
    case .anthropic: CloudSearchFixtures.anthropic
    }
}

// MARK: - Support des fournisseurs

@Suite("CloudWebSearchProvider — fournisseurs supportés")
struct CloudWebSearchSupportTests {
    @Test("Les trois fournisseurs documentés sont supportés (Gemini volontairement absent)", arguments: ["perplexity", "openai", "claude"])
    func supportedProviders(providerID: String) {
        #expect(CloudWebSearchProvider.isSupported(providerID: providerID))
    }

    @Test(
        "Les autres fournisseurs (catalogue ou personnalisés) ne le sont pas",
        arguments: ["mistral", "groq", "deepseek", "openrouter", "xai", "together", "fireworks", "cerebras", "custom-1A2B", "", "OpenAI"]
    )
    func unsupportedProviders(providerID: String) {
        #expect(!CloudWebSearchProvider.isSupported(providerID: providerID))
        #expect(CloudWebSearchService(providerID: providerID) == nil)
    }

    @Test("Gemini n'a plus de recherche cloud : Google impose ses Search Suggestions avec google_search")
    func geminiIsNotSupported() {
        #expect(!CloudWebSearchProvider.isSupported(providerID: "gemini"))
        #expect(CloudWebSearchService(providerID: "gemini") == nil)
        #expect(CloudWebSearchService(rawValue: "gemini") == nil)
    }

    /// Les constantes sont recopiées (les sources sont isolées au main actor) : ce test empêche
    /// qu'elles dérivent.
    @MainActor
    @Test("Les identifiants restent alignés sur la sélection cloud et le catalogue")
    func identifiersMatchTheirSources() {
        #expect(CloudWebSearchService.anthropic.rawValue == CloudProviderSelectionResolver.claudeProviderID)
        let catalogIDs = Set(CloudProviderCatalog.presets.map(\.id))
        for service in [CloudWebSearchService.perplexity, .openAI] {
            #expect(catalogIDs.contains(service.rawValue))
        }
    }

    @Test("Modèle par défaut : le moins cher qui supporte la recherche, jamais pour Perplexity")
    func defaultModels() {
        #expect(CloudWebSearchService.perplexity.defaultModel == nil)
        #expect(CloudWebSearchService.openAI.defaultModel == "gpt-6-luna")
        #expect(CloudWebSearchService.anthropic.defaultModel == "claude-haiku-5-5")
    }

    @Test("Le provider s'annonce comme recherche du fournisseur IA")
    func kindIsCloudProviderWebSearch() {
        for service in CloudWebSearchService.allCases {
            let (provider, _) = cloudProvider(service, body: "{}")
            #expect(provider.kind == .cloudProviderWebSearch)
        }
    }

    @Test("Un modèle personnalisé remplace le défaut, un modèle vide non")
    func modelOverride() {
        #expect(cloudProvider(.openAI, body: "{}", model: "gpt-5-nano").provider.model == "gpt-5-nano")
        #expect(cloudProvider(.openAI, body: "{}", model: "  ").provider.model == "gpt-6-luna")
        #expect(cloudProvider(.perplexity, body: "{}", model: "sonar").provider.model == "sonar")
    }
}

// MARK: - Fabrique à partir de la sélection cloud

private struct CloudSearchFakeKeyStore: APIKeyStoring {
    let keys: [String: String]
    func apiKey(account: String) throws -> String? { keys[account] }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private struct CloudSearchBrokenKeyStore: APIKeyStoring {
    struct Failure: Error {}
    func apiKey(account: String) throws -> String? { throw Failure() }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
@Suite("CloudWebSearchProvider — fabrique")
struct CloudWebSearchFactoryTests {
    private let stored = CloudSearchFakeKeyStore(keys: ["claude": "k-claude", "openai": "k-openai", "mistral": "k-mistral"])

    @Test("Une sélection supportée avec clé donne un provider au modèle par défaut")
    func supportedSelectionWithKey() throws {
        // Le modèle de CHAT choisi (ici un modèle coûteux) ne doit pas servir à la recherche.
        let selection = CloudProviderSelection(providerID: "claude", model: "claude-opus-5-5")
        let provider = try CloudWebSearchProvider.make(for: selection, keyStore: stored)
        #expect(provider?.service == .anthropic)
        #expect(provider?.model == "claude-haiku-5-5")
    }

    @Test("Aucune sélection : pas de provider")
    func noSelection() throws {
        #expect(try CloudWebSearchProvider.make(for: nil, keyStore: stored) == nil)
    }

    @Test("Fournisseur non supporté : pas de provider, même avec une clé")
    func unsupportedSelection() throws {
        let selection = CloudProviderSelection(providerID: "mistral", model: "mistral-large-latest")
        #expect(try CloudWebSearchProvider.make(for: selection, keyStore: stored) == nil)
    }

    @Test("Fournisseur supporté sans clé enregistrée : pas de provider")
    func missingKey() throws {
        let selection = CloudProviderSelection(providerID: "perplexity", model: "sonar")
        #expect(try CloudWebSearchProvider.make(for: selection, keyStore: stored) == nil)
    }

    @Test("Clé réduite à des espaces : pas de provider")
    func blankKey() throws {
        let blank = CloudSearchFakeKeyStore(keys: ["openai": "   \n"])
        let selection = CloudProviderSelection(providerID: "openai", model: "gpt-4o-mini")
        #expect(try CloudWebSearchProvider.make(for: selection, keyStore: blank) == nil)
    }

    @Test("Keychain illisible : erreur explicite, distincte de « pas de clé »")
    func brokenKeychain() {
        let selection = CloudProviderSelection(providerID: "openai", model: "gpt-4o-mini")
        #expect(throws: SearchKeyStoreError.keychainFailure) {
            try CloudWebSearchProvider.make(for: selection, keyStore: CloudSearchBrokenKeyStore())
        }
    }

    @Test("Keychain illisible mais fournisseur non supporté : pas d'accès, donc pas d'erreur")
    func brokenKeychainIgnoredForUnsupportedProvider() throws {
        let selection = CloudProviderSelection(providerID: "mistral", model: "x")
        #expect(try CloudWebSearchProvider.make(for: selection, keyStore: CloudSearchBrokenKeyStore()) == nil)
    }

    @Test("La clé est lue sous le compte égal au providerID")
    func keyAccountIsProviderID() async throws {
        let selection = CloudProviderSelection(providerID: "openai", model: "gpt-4o-mini")
        let requester = BYOKTestRequester(body: CloudSearchFixtures.openAI)
        let made = try CloudWebSearchProvider.make(for: selection, keyStore: stored, requester: requester)
        let provider = try #require(made)
        _ = try await provider.search(query: "test", options: WebSearchOptions())
        #expect(requester.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer k-openai")
    }
}

// MARK: - Perplexity

@Suite("CloudWebSearchProvider — Perplexity (API Search)")
struct CloudWebSearchPerplexityTests {
    @Test("Extrait titre, URL et extrait ; dédoublonne ; ignore les liens non http(s)")
    func parsesResults() async throws {
        let (provider, _) = cloudProvider(.perplexity, body: CloudSearchFixtures.perplexity)
        let response = try await provider.search(query: "swift concurrency", options: WebSearchOptions())

        #expect(response.results.map(\.url) == [
            "https://developer.apple.com/documentation/swift/concurrency",
            "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/",
        ])
        #expect(response.results[0].title == "Swift Concurrency | Apple Developer Documentation")
        // Espaces et retours à la ligne normalisés.
        #expect(response.results[0].content == "Perform asynchronous and parallel operations in your app.")
        #expect(response.suggestions.isEmpty)
    }

    @Test("Forme de la requête : POST /search, clé en Bearer, jamais dans l'URL")
    func requestShape() async throws {
        let (provider, requester) = cloudProvider(.perplexity, body: CloudSearchFixtures.perplexity)
        _ = try await provider.search(
            query: "Canal+ C++", options: WebSearchOptions(language: "fr-FR", maxResults: 7)
        )

        let request = try #require(requester.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.perplexity.ai/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(cloudSearchSecret)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = requestBody(request)
        #expect(body["query"] as? String == "Canal+ C++")
        #expect(body["max_results"] as? Int == 7)
        #expect(body["search_language_filter"] as? [String] == ["fr"])
        #expect(body["max_tokens_per_page"] as? Int == 512)
        #expect(body["model"] == nil)
    }

    @Test("max_results est borné à 1…20 ; langue illisible ignorée")
    func clampsParameters() async throws {
        let (provider, requester) = cloudProvider(.perplexity, body: CloudSearchFixtures.perplexity)
        _ = try await provider.search(query: "a", options: WebSearchOptions(language: "123", maxResults: 99))
        _ = try await provider.search(query: "a", options: WebSearchOptions(maxResults: 0))

        let first = requestBody(try #require(requester.requests.first))
        let second = requestBody(try #require(requester.requests.last))
        #expect(first["max_results"] as? Int == 20)
        #expect(first["search_language_filter"] == nil)
        #expect(second["max_results"] as? Int == 1)
    }

    @Test("Un extrait trop long est tronqué")
    func truncatesLongSnippets() async throws {
        let long = String(repeating: "mot ", count: 400)
        let body = #"{"results":[{"title":"T","url":"https://exemple.fr/a","snippet":"\#(long)"}]}"#
        let (provider, _) = cloudProvider(.perplexity, body: body)
        let response = try await provider.search(query: "a", options: WebSearchOptions())
        let content = try #require(response.results.first?.content)
        #expect(content.count == CloudWebSearchProvider.maxSnippetLength + 1)
        #expect(content.hasSuffix("…"))
    }
}

// MARK: - OpenAI

@Suite("CloudWebSearchProvider — OpenAI (Responses API)")
struct CloudWebSearchOpenAITests {
    @Test("Citations titrées d'abord, URL consultées ensuite, suivi utm_source retiré, dédoublonné")
    func parsesCitationsAndSources() async throws {
        let (provider, _) = cloudProvider(.openAI, body: CloudSearchFixtures.openAI)
        let response = try await provider.search(query: "finale ligue des champions", options: WebSearchOptions())

        #expect(response.results.count == 2)
        #expect(response.results[0].url == "https://www.lemonde.fr/sport/article/2026/05/31/finale.html")
        #expect(response.results[0].title == "Finale de la Ligue des champions — Le Monde")
        // `%2B` conservé tel quel (pas réencodé en `+`), seul `utm_source=openai` disparaît.
        #expect(response.results[1].url == "https://example.org/seule-source?id=a%2Bb")
        // Source sans titre : le nom d'hôte sert de titre.
        #expect(response.results[1].title == "example.org")
    }

    @Test("Forme de la requête : Responses API, outil web_search, recherche forcée, sources incluses")
    func requestShape() async throws {
        let (provider, requester) = cloudProvider(.openAI, body: CloudSearchFixtures.openAI)
        _ = try await provider.search(query: "finale ligue des champions", options: WebSearchOptions())

        let request = try #require(requester.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(cloudSearchSecret)")

        let body = requestBody(request)
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["include"] as? [String] == ["web_search_call.action.sources"])
        #expect(body["max_output_tokens"] as? Int == CloudWebSearchProvider.openAIMaxOutputTokens)
        #expect(body["store"] as? Bool == false)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search")
        #expect(tools[0]["search_context_size"] as? String == "low")
        #expect((body["input"] as? String)?.contains("finale ligue des champions") == true)
    }

    @Test("Aucun outil appelé : réponse vide valide, pas une erreur")
    func noSearchPerformed() async throws {
        let body = #"{"id":"r","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Bonjour","annotations":[]}]}]}"#
        let (provider, _) = cloudProvider(.openAI, body: body)
        let response = try await provider.search(query: "bonjour", options: WebSearchOptions())
        #expect(response.results.isEmpty)
    }
}

// MARK: - Anthropic

@Suite("CloudWebSearchProvider — Anthropic (outil serveur web_search)")
struct CloudWebSearchAnthropicTests {
    @Test("Sources = web_search_tool_result ; extrait = cited_text de la citation de même URL")
    func parsesResultsAndCitations() async throws {
        let (provider, _) = cloudProvider(.anthropic, body: CloudSearchFixtures.anthropic)
        let response = try await provider.search(query: "claude shannon", options: WebSearchOptions())

        #expect(response.results.count == 2)
        #expect(response.results[0].url == "https://en.wikipedia.org/wiki/Claude_Shannon")
        #expect(response.results[0].title == "Claude Shannon - Wikipedia")
        #expect(response.results[0].content?.hasPrefix("Claude Elwood Shannon (April 30, 1916") == true)
        // Pas de citation pour cette source : pas d'extrait inventé.
        #expect(response.results[1].url == "https://www.britannica.com/biography/Claude-Shannon")
        #expect(response.results[1].content == nil)
    }

    @Test("Forme de la requête : Messages API, web_search_20250305, une seule recherche")
    func requestShape() async throws {
        let (provider, requester) = cloudProvider(.anthropic, body: CloudSearchFixtures.anthropic)
        _ = try await provider.search(query: "claude shannon", options: WebSearchOptions())

        let request = try #require(requester.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == cloudSearchSecret)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = requestBody(request)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == CloudWebSearchProvider.maxOutputTokens)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "web_search_20250305")
        #expect(tools[0]["name"] as? String == "web_search")
        #expect(tools[0]["max_uses"] as? Int == 1)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test("Erreur d'outil reçue avec un HTTP 200", arguments: [
        ("too_many_requests", WebSearchError.rateLimited),
        ("unavailable", WebSearchError.unavailable),
        ("max_uses_exceeded", WebSearchError.invalidResponse),
        ("query_too_long", WebSearchError.invalidResponse),
        ("invalid_tool_input", WebSearchError.invalidResponse),
    ])
    func toolErrorInsideSuccessfulResponse(code: String, expected: WebSearchError) async {
        let (provider, _) = cloudProvider(.anthropic, body: CloudSearchFixtures.anthropicToolError(code: code))
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == expected)
    }

    @Test("Une erreur d'outil n'écrase pas des sources déjà obtenues")
    func toolErrorKeepsExistingResults() async throws {
        let body = """
        { "content": [
            { "type": "web_search_tool_result", "tool_use_id": "a",
              "content": [ { "type": "web_search_result", "url": "https://exemple.fr/ok", "title": "OK" } ] },
            { "type": "web_search_tool_result", "tool_use_id": "b",
              "content": { "type": "web_search_tool_result_error", "error_code": "max_uses_exceeded" } }
        ], "stop_reason": "pause_turn" }
        """
        let (provider, _) = cloudProvider(.anthropic, body: body)
        let response = try await provider.search(query: "x", options: WebSearchOptions())
        #expect(response.results.map(\.url) == ["https://exemple.fr/ok"])
    }

    @Test("Recherche sans résultat (content vide) : réponse vide valide")
    func emptyResultList() async throws {
        let body = #"{"content":[{"type":"web_search_tool_result","tool_use_id":"a","content":[]}]}"#
        let (provider, _) = cloudProvider(.anthropic, body: body)
        let response = try await provider.search(query: "x", options: WebSearchOptions())
        #expect(response.results.isEmpty)
    }

    @Test("Recherche web désactivée par l'administrateur (400) : source indisponible")
    func webSearchDisabledByAdministrator() async {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"Web search is not enabled for this organization"}}"#
        let (provider, _) = cloudProvider(.anthropic, status: 400, body: body)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .unavailable)
    }
}

// MARK: - Erreurs communes

@Suite("CloudWebSearchProvider — erreurs")
struct CloudWebSearchErrorTests {
    @Test(
        "Statut HTTP -> WebSearchError",
        arguments: [
            (401, WebSearchError.unauthorized), (403, .unauthorized), (408, .timeout),
            (429, .rateLimited), (500, .unavailable), (503, .unavailable), (529, .unavailable),
            (400, .invalidResponse), (404, .invalidResponse), (422, .invalidResponse),
        ]
    )
    func statusMapping(status: Int, expected: WebSearchError) async {
        for service in CloudWebSearchService.allCases {
            let (provider, _) = cloudProvider(service, status: status, body: #"{"error":"x"}"#)
            let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
            #expect(error as? WebSearchError == expected, "service \(service), statut \(status)")
        }
    }

    @Test("Réponse qui n'est pas du JSON : invalidResponse", arguments: CloudWebSearchService.allCases)
    func invalidJSON(service: CloudWebSearchService) async {
        let (provider, _) = cloudProvider(service, body: "<html>Bad gateway</html>")
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .invalidResponse)
    }

    @Test("Réseau coupé : noConnection ; délai dépassé : timeout", arguments: CloudWebSearchService.allCases)
    func transportErrors(service: CloudWebSearchService) async {
        let offline = BYOKTestRequester { _ in throw URLError(.notConnectedToInternet) }
        let slow = BYOKTestRequester { _ in throw URLError(.timedOut) }
        let offlineError = await byokThrownError {
            _ = try await CloudWebSearchProvider(service: service, apiKey: "k", requester: offline)
                .search(query: "x", options: WebSearchOptions())
        }
        let slowError = await byokThrownError {
            _ = try await CloudWebSearchProvider(service: service, apiKey: "k", requester: slow)
                .search(query: "x", options: WebSearchOptions())
        }
        #expect(offlineError as? WebSearchError == .noConnection)
        #expect(slowError as? WebSearchError == .timeout)
    }

    /// Si l'annulation devenait `.unavailable`, l'orchestrateur passerait à la source suivante
    /// (peut-être payante) alors que l'utilisateur vient d'appuyer sur Stop.
    @Test("Annulation : CancellationError, jamais une erreur de source", arguments: CloudWebSearchService.allCases)
    func cancellation(service: CloudWebSearchService) async {
        let cancelled = BYOKTestRequester { _ in throw URLError(.cancelled) }
        let error = await byokThrownError {
            _ = try await CloudWebSearchProvider(service: service, apiKey: "k", requester: cancelled)
                .search(query: "x", options: WebSearchOptions())
        }
        #expect(error is CancellationError)
    }

    @Test("Requête vide : aucun appel payant", arguments: CloudWebSearchService.allCases)
    func emptyQueryMakesNoCall(service: CloudWebSearchService) async throws {
        let (provider, requester) = cloudProvider(service, body: fixture(for: service))
        let response = try await provider.search(query: " \n\t ", options: WebSearchOptions())
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
    }

    @Test("Clé vide : missingKey sans appel réseau", arguments: CloudWebSearchService.allCases)
    func missingKeyMakesNoCall(service: CloudWebSearchService) async {
        let requester = BYOKTestRequester(body: fixture(for: service))
        let provider = CloudWebSearchProvider(service: service, apiKey: "  ", requester: requester)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .missingKey)
        #expect(requester.requests.isEmpty)
    }

    /// Un serveur BYOK malveillant peut renvoyer la clé dans son JSON d'erreur : rien de ce
    /// qu'il écrit ne doit ressortir, ni dans l'erreur ni dans son message affichable.
    @Test("La clé et le corps d'erreur n'apparaissent jamais dans l'erreur", arguments: CloudWebSearchService.allCases)
    func secretNeverLeaks(service: CloudWebSearchService) async throws {
        let hostile = #"{"error":{"message":"Incorrect API key provided: \#(cloudSearchSecret)"}}"#
        let (provider, requester) = cloudProvider(service, status: 401, body: hostile)
        let thrown = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        let error = try #require(thrown as? WebSearchError)

        #expect(!String(describing: error).contains(cloudSearchSecret))
        #expect(!error.userFacingMessage.contains(cloudSearchSecret))
        #expect(!error.userFacingMessage.contains("Incorrect"))
        // Ni dans l'URL, ni dans l'affichage du provider (`SearchSecret` masque la valeur).
        let url = try #require(requester.requests.first?.url).absoluteString
        #expect(!url.contains(cloudSearchSecret))

        // Provider « neuf » : le faux transport de test garde les requêtes (donc l'en-tête qui
        // porte la clé) et les ferait apparaître dans un `dump`, ce qui fausserait la mesure.
        let fresh = CloudWebSearchProvider(
            service: service, apiKey: cloudSearchSecret, requester: URLSessionDataRequester()
        )
        #expect(!"\(fresh)".contains(cloudSearchSecret))
        #expect(!String(reflecting: fresh).contains(cloudSearchSecret))
        var dumped = ""
        dump(fresh, to: &dumped)
        #expect(!dumped.contains(cloudSearchSecret))
    }
}

// MARK: - Dédoublonnage et plafond

@Suite("CloudWebSearchProvider — dédoublonnage")
struct CloudWebSearchDedupTests {
    private func result(_ url: String, title: String = "T", content: String? = nil) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    @Test("Hôte en minuscules, fragment et `/` final ignorés, requête conservée")
    func normalization() {
        let key = CloudWebSearchSources.normalizedKey(for:)
        #expect(key("https://Exemple.FR/page/#intro") == key("https://exemple.fr/page"))
        #expect(key("https://exemple.fr/page?id=1") != key("https://exemple.fr/page?id=2"))
        #expect(key("https://exemple.fr") == key("https://exemple.fr/"))
    }

    @Test("La première occurrence est gardée et reçoit l'extrait d'un doublon")
    func keepsFirstAndFillsSnippet() {
        let merged = CloudWebSearchSources.deduplicated([
            result("https://a.fr/x", title: "Premier"),
            result("https://b.fr/y", content: "B"),
            result("https://A.fr/x/", title: "Doublon", content: "extrait récupéré"),
        ], limit: 10)
        #expect(merged.map(\.title) == ["Premier", "T"])
        #expect(merged[0].content == "extrait récupéré")
    }

    @Test("Le plafond maxResults est respecté, au moins 1")
    func capsResults() async throws {
        let items = (1...9).map { #"{"title":"T\#($0)","url":"https://exemple.fr/\#($0)","snippet":"s"}"# }
        let body = #"{"results":[\#(items.joined(separator: ","))]}"#
        let (provider, _) = cloudProvider(.perplexity, body: body)
        let three = try await provider.search(query: "a", options: WebSearchOptions(maxResults: 3))
        let zero = try await provider.search(query: "a", options: WebSearchOptions(maxResults: 0))
        #expect(three.results.count == 3)
        #expect(zero.results.count == 1)
    }

    @Test("Le suivi utm_source=openai est retiré, les autres paramètres restent")
    func removesOpenAITracking() {
        let strip = CloudWebSearchSources.removingOpenAITracking(from:)
        #expect(strip("https://exemple.fr/a?utm_source=openai") == "https://exemple.fr/a")
        #expect(strip("https://exemple.fr/a?x=1&utm_source=openai&y=2") == "https://exemple.fr/a?x=1&y=2")
        #expect(strip("https://exemple.fr/a?utm_source=newsletter") == "https://exemple.fr/a?utm_source=newsletter")
        #expect(strip("https://exemple.fr/a") == "https://exemple.fr/a")
    }
}
