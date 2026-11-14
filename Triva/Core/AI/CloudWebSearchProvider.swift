//
//  CloudWebSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

/// Les quatre fournisseurs IA cloud dont Triva sait utiliser la recherche web intégrée.
///
/// `rawValue` = `providerID` de `CloudProviderSelection` (« claude » pour Anthropic, l'`id` du
/// preset du catalogue pour les trois autres). Les constantes sont recopiées ici, et non lues dans
/// `CloudProviderSelectionResolver.claudeProviderID` / `CloudProviderCatalog`, parce que ces deux
/// types sont isolés au main actor (défaut du projet) : cette énumération doit rester utilisable
/// depuis n'importe quel contexte. Un test vérifie qu'elles restent égales à leurs sources.
///
/// Les fournisseurs personnalisés ont des identifiants à part (voir `CloudProviderSelection`) :
/// aucune collision possible, ils tombent toujours dans « non supporté ».
nonisolated enum CloudWebSearchService: String, Sendable, Equatable, CaseIterable {
    case perplexity
    case openAI = "openai"
    case anthropic = "claude"

    init?(providerID: String) {
        self.init(rawValue: providerID)
    }

    /// Modèle utilisé pour la recherche — JAMAIS celui que l'utilisateur a choisi pour le chat.
    /// Ce dernier peut être un modèle haut de gamme (une recherche de repli coûterait alors
    /// plusieurs fois plus cher pour une sortie de quelques mots) ou un modèle qui ne sait pas
    /// chercher. On prend donc le moins cher dont la doc officielle garantit la recherche web.
    /// `nil` pour Perplexity : l'API Search n'a pas de modèle (voir `CloudWebSearchProvider`).
    var defaultModel: String? {
        switch self {
        case .perplexity: nil
        case .openAI: "gpt-6-luna"
        case .anthropic: "claude-haiku-5-5"
        }
    }
}

/// Recherche web « prêtée » par le fournisseur IA cloud de l'utilisateur : le dernier recours
/// avant les sources ouvertes quand ni clé de recherche ni instance SearXNG ne répond.
///
/// On ne demande JAMAIS une réponse rédigée : seuls les RÉSULTATS SOURCÉS (titre, URL, extrait)
/// sont gardés, Triva rédige lui-même sa réponse et ses citations. Le prompt est donc minimal
/// (« une phrase ») et la sortie plafonnée : la sortie est payée par l'utilisateur.
///
/// COÛT : chaque recherche de repli est UN APPEL PAYANT sur le compte de l'utilisateur (zéro
/// serveur, la requête part de l'appareil vers le fournisseur). Ordres de grandeur, d'après les
/// tarifs publiés, relus le 2026-11-10 :
/// - Perplexity : 5 $ / 1 000 requêtes (API Search, aucun jeton) ;
/// - OpenAI : 10 $ / 1 000 appels + les jetons de contenu de recherche, facturés au tarif du modèle
///   (gpt-6-luna : 0,10 $ / M en entrée, 0,50 $ / M en sortie). Mesuré le 2026-11-10 avec
///   gpt-6-luna : 8 692 jetons d'entrée (dont 4 342 déjà en cache) et 62 de sortie, soit environ
///   0,0105 $ par recherche, dont 0,010 $ pour l'outil lui-même. Avec gpt-4.1-mini, le fournisseur
///   facture un bloc fixe de 8 000 jetons à 0,40 $ / M (≈ 0,0132 $) : le changement de modèle
///   baisse un peu la facture, c'est l'outil qui en fait l'essentiel ;
/// - Anthropic : 10 $ / 1 000 recherches + jetons de claude-haiku-5-5 (résultats comptés en
///   entrée, à partir de 0,10 $ / M) ; une recherche en échec n'est pas facturée ;
/// - Gemini : NON utilisé, voir « GEMINI » plus bas.
///   Tarifs Anthropic lus dans la documentation, NON essayés en réel (pas de clé).
///
/// Ces coûts sont signalés à l'utilisateur dans les Réglages (« Clés de recherche ») : voir
/// `CloudWebSearchCostNotice`.
///
/// Sources officielles consultées le 2026-10-28 (OpenAI et Anthropic relues le 2026-11-10) :
/// - Perplexity : https://docs.perplexity.ai/api-reference/search-post.md (endpoint, champs,
///   réponse `results[]`), https://docs.perplexity.ai/docs/getting-started/pricing.md ;
///   https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview.md ;
/// - OpenAI : https://developers.openai.com/api/docs/guides/tools-web-search (outil `web_search`,
///   `include: ["web_search_call.action.sources"]`, `tool_choice: "required"`, annotations
///   `url_citation`), https://developers.openai.com/api/reference/resources/responses/methods/create
///   (forme de `action.sources`), https://developers.openai.com/api/docs/pricing ;
/// - Anthropic : https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool
///   (outil `web_search_20250305`, blocs `web_search_tool_result`, erreurs dans un 200) ;
///
/// ÉCARTS ASSUMÉS avec la mission d'origine :
/// - PERPLEXITY n'utilise pas les modèles Sonar. La doc officielle indique « Sonar Chat
///   Completions support ended on September 27, 2026 » (remplacé par l'API Agent). `POST /search`
///   renvoie exactement ce qu'on veut (titre, URL, extrait) sans aucune génération, donc sans
///   rien payer pour du texte inutile. Même clé API que le chat.
/// - ANTHROPIC utilise `web_search_20250305` (recherche simple) et non `web_search_20260209` ou
///   plus récent : ces versions passent par l'exécution de code (filtrage dynamique), ajoutent
///   des blocs imbriqués et de la latence, pour un gain nul quand on ne lit que les sources.
///   Pas de snippet dans `web_search_result` : on utilise `cited_text` (≤150 caractères) des
///   citations du texte quand le modèle en produit, sinon `content` reste `nil` (la page est de
///   toute façon récupérée ensuite par le scraping).
/// - GEMINI : volontairement ABSENT (décision de Ben, 2026-11-13). Google impose d'afficher ses
///   « Search Suggestions » sans les modifier dès qu'on utilise sa recherche intégrée (outil
///   `google_search`, sources `vertexaisearch`), ce que Triva ne fait pas. Gemini reste un moteur de
///   RÉPONSE comme OpenAI ou Claude, alimenté par la recherche de Triva (SearXNG, Brave, Tavily).
///
/// CLÉ JAMAIS DIVULGUÉE : la clé n'existe qu'en en-tête (`Authorization`, `x-api-key`), jamais dans une URL ; elle est portée par `SearchSecret` (affichage masqué).
/// Seul un `WebSearchError` à message fixe sort d'ici : ni corps de réponse ni message du
/// fournisseur n'est relayé (un serveur malveillant pourrait y glisser la clé).
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search` (décodage hors du main actor). La clé
/// est lue au Keychain côté main actor dans `make(selection:…)`, puis le provider autonome — une
/// valeur `Sendable` qui contient sa clé — est passé à l'orchestrateur (même principe que
/// `SearchKeyStore`).
nonisolated struct CloudWebSearchProvider: WebSearchProviding {
    /// Délai d'une requête. Plus long que les 10 s des sources de recherche pures
    /// (`BYOKSearchHTTP.timeout`) : ici un modèle de langage lance la recherche puis résume.
    static let requestTimeout: TimeInterval = 30
    /// Plafond de sortie (jetons) : la phrase demandée est courte, les sources sont dans les
    /// métadonnées, pas dans le texte. Large pour Anthropic : son modèle actuel
    /// (claude-haiku-5-5 à réflexion adaptative) compte la RÉFLEXION dans
    /// ce plafond, et un plafond trop bas couperait la génération avant l'appel à l'outil de
    /// recherche. Un plafond n'est facturé que s'il est consommé : le relever ne coûte rien de plus
    /// quand le modèle reste bref. (Passé de 256 à 1 024 le 2026-11-10 avec le changement de modèle ;
    /// non essayé en réel pour ces deux fournisseurs, faute de clé.)
    static let maxOutputTokens = 1024
    /// OpenAI : minimum accepté 16. gpt-6-luna a utilisé 62 jetons dont 33 de réflexion pour une
    /// question simple (mesuré le 2026-11-10) : 256 laisse de la marge. Une réponse « incomplete »
    /// garde de toute façon ses sources, `CloudWebSearchParsers.openAI` ne lit pas le statut.
    static let openAIMaxOutputTokens = 256
    /// Longueur maximale d'un extrait : au-delà, ce serait du contenu de page, pas un extrait.
    static let maxSnippetLength = 500
    static let perplexityMaxResults = 20

    let kind: WebSearchSourceKind = .cloudProviderWebSearch
    let service: CloudWebSearchService

    let model: String?

    private let apiKey: SearchSecret
    private let requester: any HTTPDataRequesting

    /// `model` : remplace le modèle par défaut (tests, ou futur réglage). Ignoré par Perplexity.
    init(
        service: CloudWebSearchService,
        apiKey: String,
        model: String? = nil,
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) {
        self.service = service
        self.apiKey = SearchSecret(apiKey)
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (trimmedModel?.isEmpty ?? true) ? service.defaultModel : trimmedModel
        self.requester = requester
    }

    // MARK: - Fabrique

    /// Ce fournisseur sait-il chercher sur le web ? `false` pour Mistral, Groq, DeepSeek… et pour
    /// tout fournisseur personnalisé : leurs API compatibles OpenAI n'ont pas d'outil de recherche.
    static func isSupported(providerID: String) -> Bool {
        CloudWebSearchService(providerID: providerID) != nil
    }

    /// Provider construit à partir de la sélection cloud courante. Renvoie `nil` (la source est
    /// simplement sautée, aucune requête payante vouée à l'échec) si :
    /// - aucune sélection, ou fournisseur non supporté (`isSupported`) ;
    /// - aucune clé n'est enregistrée pour ce fournisseur, ou elle est réduite à des espaces.
    /// Lève `SearchKeyStoreError.keychainFailure` si le Keychain est illisible : ce n'est pas
    /// « pas de clé », l'appelant doit pouvoir le distinguer (même contrat que
    /// `SearchKeyStore.credentials(for:)`). La clé est cherchée sous le compte `providerID`,
    /// comme le font `CloudBYOKProvider` et `OpenAICompatibleProvider`.
    ///
    /// `@MainActor` : `APIKeyStoring` / `KeychainAPIKeyStore` sont isolés au main actor. Le
    /// modèle de la sélection est volontairement ignoré (voir `CloudWebSearchService.defaultModel`).
    @MainActor
    static func make(
        for selection: CloudProviderSelection?,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) throws -> CloudWebSearchProvider? {
        guard let selection, let service = CloudWebSearchService(providerID: selection.providerID) else {
            return nil
        }
        let storedKey: String?
        do {
            storedKey = try keyStore.apiKey(account: selection.providerID)
        } catch {
            throw SearchKeyStoreError.keychainFailure
        }
        let secret = SearchSecret(storedKey ?? "")
        guard !secret.isEmpty else { return nil }
        return CloudWebSearchProvider(service: service, apiKey: secret.value, requester: requester)
    }

    // MARK: - Recherche

    /// Une requête, un appel payant. Requête vide : aucun appel. Les catégories `.academic` et
    /// `.discussion` sont traitées comme `.general` (le moteur du fournisseur est généraliste ;
    /// lever `.unsupportedCategory` ferait sauter une source qui marche). Zéro source n'est pas
    /// une erreur : le modèle a pu juger la recherche inutile, c'est une réponse vide valide.
    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard !apiKey.isEmpty else { throw WebSearchError.missingKey }
        guard let cleanQuery = BYOKSearchHTTP.trimmedQuery(query) else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: cleanQuery, options: options)
        let service = self.service
        let data = try await BYOKSearchHTTP.send(request, via: requester) { status, body in
            CloudWebSearchErrors.classify(status: status, body: body, service: service)
        }
        return try Self.parse(data, service: service, maxResults: options.maxResults)
    }

    /// Prompt commun aux deux fournisseurs à modèle (OpenAI, Anthropic) : court, et il interdit la rédaction longue.
    static func prompt(for query: String) -> String {
        "Recherche sur le web puis réponds en une seule phrase très courte. Question : \(query)"
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        switch service {
        case .perplexity: try perplexityRequest(query: query, options: options)
        case .openAI: try openAIRequest(query: query)
        case .anthropic: try anthropicRequest(query: query)
        }
    }

    private func perplexityRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        var body: [String: Any] = [
            "query": query,
            "max_results": BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.perplexityMaxResults),
            // Borne le contenu extrait par page : l'extrait n'est qu'un aperçu.
            "max_tokens_per_page": 512,
        ]
        if let language = BYOKSearchHTTP.baseLanguage(from: options.language), language.count == 2 {
            body["search_language_filter"] = [language]
        }
        var request = try makeRequest(host: "api.perplexity.ai", path: "/search", body: body)
        request.setValue("Bearer \(apiKey.value)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func openAIRequest(query: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model ?? CloudWebSearchService.openAI.defaultModel ?? "",
            "input": Self.prompt(for: query),
            // `search_context_size: low` : le moins de contenu de page injecté, donc le moins de
            // jetons facturés ; on ne lit que les sources.
            "tools": [["type": "web_search", "search_context_size": "low"]],
            // Documenté : force l'appel à l'outil au lieu de laisser le modèle répondre de tête.
            "tool_choice": "required",
            // Toutes les URL consultées, pas seulement celles citées dans la phrase.
            "include": ["web_search_call.action.sources"],
            "max_output_tokens": Self.openAIMaxOutputTokens,
            "store": false,
        ]
        var request = try makeRequest(host: "api.openai.com", path: "/v1/responses", body: body)
        request.setValue("Bearer \(apiKey.value)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func anthropicRequest(query: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model ?? CloudWebSearchService.anthropic.defaultModel ?? "",
            "max_tokens": Self.maxOutputTokens,
            "messages": [["role": "user", "content": Self.prompt(for: query)]],
            // `max_uses: 1` : une recherche = 10 $ / 1 000, on plafonne à une seule.
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 1]],
        ]
        var request = try makeRequest(host: "api.anthropic.com", path: "/v1/messages", body: body)
        request.setValue(apiKey.value, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudModelListService.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func makeRequest(host: String, path: String, body: [String: Any]) throws -> URLRequest {
        let url = try BYOKSearchHTTP.makeURL(host: host, path: path, queryItems: [])
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { throw WebSearchError.invalidResponse }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Réponse

    /// Décode la réponse du fournisseur, dédoublonne et plafonne. Ne lève que des `WebSearchError`.
    static func parse(_ data: Data, service: CloudWebSearchService, maxResults: Int) throws -> SearXNGSearchResponse {
        let raw: [SearXNGSearchResult]
        switch service {
        case .perplexity: raw = try CloudWebSearchParsers.perplexity(data)
        case .openAI: raw = try CloudWebSearchParsers.openAI(data)
        case .anthropic: raw = try CloudWebSearchParsers.anthropic(data)
        }
        let results = CloudWebSearchSources.deduplicated(raw, limit: max(1, maxResults))
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

// MARK: - Erreurs

/// Correspondance statut HTTP -> `WebSearchError`, avec les particularités de chaque fournisseur.
/// Le corps n'est lu que pour CHOISIR un cas, jamais relayé.
nonisolated enum CloudWebSearchErrors {
    static func classify(status: Int, body: Data, service: CloudWebSearchService) -> WebSearchError {
        let text = String(decoding: body, as: UTF8.self)
        switch (service, status) {
        case (.anthropic, 400) where mentionsDisabledWebSearch(text):
            // Organisation dont l'administrateur a désactivé la recherche web (Console Claude) :
            // 400 `invalid_request_error`. Ce n'est ni la clé ni notre requête : source indisponible.
            return .unavailable
        case (_, 529):
            // Anthropic « overloaded » ; déjà couvert par 5xx, explicité pour la lisibilité.
            return .unavailable
        default:
            return BYOKSearchHTTP.defaultError(forStatus: status)
        }
    }

    private static func mentionsDisabledWebSearch(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("web search") || lowered.contains("web_search")
    }

    /// Codes d'erreur d'un bloc `web_search_tool_result_error` (Anthropic, reçus avec un HTTP 200).
    static func anthropicToolError(code: String?) -> WebSearchError {
        switch code {
        case "too_many_requests": .rateLimited
        case "unavailable": .unavailable
        default: .invalidResponse
        }
    }
}

// MARK: - Dédoublonnage

nonisolated enum CloudWebSearchSources {
    /// Dédoublonne sur l'URL normalisée en gardant la PREMIÈRE occurrence (l'ordre du fournisseur
    /// est un classement de pertinence) ; si elle n'a pas d'extrait et qu'un doublon en a un, il
    /// le lui donne. Plafonne ensuite à `limit`.
    static func deduplicated(_ results: [SearXNGSearchResult], limit: Int) -> [SearXNGSearchResult] {
        var order: [String] = []
        var byKey: [String: SearXNGSearchResult] = [:]
        for result in results {
            let key = normalizedKey(for: result.url)
            guard let existing = byKey[key] else {
                order.append(key)
                byKey[key] = result
                continue
            }
            if existing.content == nil, let content = result.content {
                byKey[key] = SearXNGSearchResult(
                    title: existing.title, url: existing.url, content: content,
                    imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
                )
            }
        }
        return Array(order.compactMap { byKey[$0] }.prefix(limit))
    }

    /// Hôte en minuscules, sans fragment, sans `/` final : « https://Exemple.fr/page/#intro » et
    /// « https://exemple.fr/page » désignent la même source. La requête est conservée (elle peut
    /// distinguer deux pages).
    static func normalizedKey(for rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.fragment = nil
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.string ?? rawURL
    }

    /// OpenAI ajoute `utm_source=openai` aux liens de ses citations. On le retire : il pollue
    /// l'affichage, empêche le dédoublonnage et trahit l'origine du lien aux sites cités.
    /// Travaille sur la forme encodée : décoder puis réencoder transformerait un `%2B` en `+`.
    static func removingOpenAITracking(from rawURL: String) -> String {
        guard rawURL.lowercased().contains("utm_source=openai"),
              var components = URLComponents(string: rawURL),
              let items = components.percentEncodedQueryItems
        else { return rawURL }
        let kept = items.filter { !($0.name.lowercased() == "utm_source" && $0.value?.lowercased() == "openai") }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string ?? rawURL
    }

    /// Texte d'extrait borné, espaces normalisés ; `nil` si vide.
    static func snippet(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = BYOKSearchHTTP.collapseWhitespace(text)
        guard !collapsed.isEmpty else { return nil }
        let limit = CloudWebSearchProvider.maxSnippetLength
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

// MARK: - Extraction des sources

/// Un décodeur par fournisseur. Tous les champs sont optionnels sauf ce qui sert à bâtir une
/// source : un champ absent ou inattendu ne doit jamais faire échouer toute la réponse (les API
/// ajoutent des champs sans prévenir). Seule une réponse qui n'est pas du JSON de la bonne forme
/// lève `.invalidResponse` (jamais le détail du décodeur : il peut citer un extrait du corps).
nonisolated enum CloudWebSearchParsers {
    /// Construit une source ; ignorée si l'URL n'est pas un lien http(s) exploitable.
    private static func result(title: String?, url: String?, content: String?) -> SearXNGSearchResult? {
        BYOKSearchHTTP.makeResult(title: title, url: url, content: CloudWebSearchSources.snippet(content))
    }

    // MARK: Perplexity — POST /search

    nonisolated private struct PerplexityResponse: Decodable {
        nonisolated struct Item: Decodable {
            let title: String?
            let url: String?
            let snippet: String?
        }
        let results: [Item]?
    }

    static func perplexity(_ data: Data) throws -> [SearXNGSearchResult] {
        let decoded = try BYOKSearchHTTP.decode(PerplexityResponse.self, from: data)
        return (decoded.results ?? []).compactMap { result(title: $0.title, url: $0.url, content: $0.snippet) }
    }

    // MARK: OpenAI — POST /v1/responses

    nonisolated private struct OpenAIResponse: Decodable {
        nonisolated struct Item: Decodable {
            nonisolated struct Action: Decodable {
                nonisolated struct Source: Decodable { let url: String? }
                let sources: [Source]?
            }
            nonisolated struct Content: Decodable {
                nonisolated struct Annotation: Decodable {
                    let type: String?
                    let url: String?
                    let title: String?
                }
                let annotations: [Annotation]?
            }
            let type: String?
            let action: Action?
            let content: [Content]?
        }
        let output: [Item]?
    }

    /// Citations d'abord (elles ont un titre), puis les sources consultées de `action.sources`
    /// (URL seule) : le dédoublonnage garde ainsi la version titrée.
    static func openAI(_ data: Data) throws -> [SearXNGSearchResult] {
        let decoded = try BYOKSearchHTTP.decode(OpenAIResponse.self, from: data)
        let items = decoded.output ?? []

        // Étapes typées explicitement : la chaîne d'un seul tenant dépassait le temps de
        // vérification de types de Swift 6.4 (« unable to type-check this expression »).
        let messages: [OpenAIResponse.Item] = items.filter { $0.type == "message" }
        let contents: [OpenAIResponse.Item.Content] = messages.flatMap { $0.content ?? [] }
        let annotations: [OpenAIResponse.Item.Content.Annotation] = contents.flatMap { $0.annotations ?? [] }
        let citations = annotations.filter { $0.type == "url_citation" }
        let cited: [SearXNGSearchResult] = citations.compactMap { annotation in
            let url: String? = annotation.url.map(CloudWebSearchSources.removingOpenAITracking)
            return result(title: annotation.title, url: url, content: nil)
        }

        let searchCalls: [OpenAIResponse.Item] = items.filter { $0.type == "web_search_call" }
        let sources: [OpenAIResponse.Item.Action.Source] = searchCalls.flatMap { $0.action?.sources ?? [] }
        let consulted: [SearXNGSearchResult] = sources.compactMap { source in
            let url: String? = source.url.map(CloudWebSearchSources.removingOpenAITracking)
            return result(title: nil, url: url, content: nil)
        }
        return cited + consulted
    }

    // MARK: Anthropic — POST /v1/messages

    nonisolated private struct AnthropicResponse: Decodable {
        nonisolated struct Block: Decodable {
            let type: String?
            let content: ToolResultContent?
            let citations: [Citation]?

            private enum CodingKeys: String, CodingKey { case type, content, citations }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                // Tolérant : seul `web_search_tool_result` nous intéresse, les autres blocs
                // (`text`, `server_tool_use`, `thinking`) peuvent avoir un `content` d'une autre forme.
                content = try? container.decodeIfPresent(ToolResultContent.self, forKey: .content)
                citations = try? container.decodeIfPresent([Citation].self, forKey: .citations)
            }
        }

        nonisolated struct Citation: Decodable {
            let url: String?
            let title: String?
            let cited_text: String?
        }

        nonisolated struct ResultItem: Decodable {
            let type: String?
            let url: String?
            let title: String?
        }

        /// `content` d'un `web_search_tool_result` : un TABLEAU de résultats, ou — en cas d'erreur,
        /// reçue avec un HTTP 200 — un objet `{ "type": "web_search_tool_result_error",
        /// "error_code": … }`.
        nonisolated enum ToolResultContent: Decodable {
            case results([ResultItem])
            case failure(code: String?)

            nonisolated private struct ErrorBody: Decodable { let error_code: String? }

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let items = try? single.decode([ResultItem].self) {
                    self = .results(items)
                } else {
                    self = .failure(code: try single.decode(ErrorBody.self).error_code)
                }
            }
        }

        let content: [Block]?
    }

    /// Sources = résultats de `web_search_tool_result` ; extrait = `cited_text` de la citation de
    /// même URL quand le texte du modèle en fournit une. Si TOUS les blocs de résultat sont des
    /// erreurs et qu'aucune source n'a été trouvée, l'erreur est remontée (sinon la chaîne de
    /// repli croirait à une recherche réussie mais vide). `stop_reason: pause_turn` n'est pas
    /// poursuivi : une seconde requête payante pour des sources déjà reçues n'aurait aucun sens.
    static func anthropic(_ data: Data) throws -> [SearXNGSearchResult] {
        let decoded = try BYOKSearchHTTP.decode(AnthropicResponse.self, from: data)
        let blocks = decoded.content ?? []

        var snippets: [String: String] = [:]
        for citation in blocks.flatMap({ $0.citations ?? [] }) {
            guard let url = citation.url, let text = citation.cited_text, !text.isEmpty else { continue }
            let key = CloudWebSearchSources.normalizedKey(for: url)
            if snippets[key] == nil { snippets[key] = text }
        }

        var results: [SearXNGSearchResult] = []
        var firstError: WebSearchError?
        for block in blocks where block.type == "web_search_tool_result" {
            switch block.content {
            case .results(let items):
                results += items.compactMap { item -> SearXNGSearchResult? in
                    guard item.type == nil || item.type == "web_search_result" else { return nil }
                    let key = item.url.map(CloudWebSearchSources.normalizedKey(for:))
                    return result(title: item.title, url: item.url, content: key.flatMap { snippets[$0] })
                }
            case .failure(let code):
                firstError = firstError ?? CloudWebSearchErrors.anthropicToolError(code: code)
            case nil:
                continue
            }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }
}
