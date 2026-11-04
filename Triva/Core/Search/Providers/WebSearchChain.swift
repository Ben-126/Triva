//
//  WebSearchChain.swift
//  Triva
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation
import OSLog

/// Chaîne de repli de la recherche web (mission RI1b, décision de Ben du 2026-10-08) : la boucle
/// que `WebSearchProviding` et `OpenSourceSearchChain` annonçaient « branchée à l'intégration ».
/// Sans elle, Triva n'interrogeait que les instances SearXNG publiques, dont la plupart bloquent
/// désormais les clients sans JavaScript : une question restait souvent sans AUCUNE source.
///
/// ORDRE D'ESSAI (le même pour les trois catégories, seule la dernière maille en dépend) :
/// 1. clés de recherche personnelles, Brave puis Tavily (`BYOKSearchSource.preferenceOrder`) ;
/// 2. SearXNG, sur le `FailoverManager` de la session (instances classées par fiabilité) ;
/// 3. recherche web du fournisseur IA cloud ACTIF — présente seulement quand le moteur de la
///    session est le cloud et qu'une clé existe (`assemble`), puisque chaque appel est payant ;
/// 4. sources ouvertes sans clé, dans l'ordre de `OpenSourceSearchChain.kinds(for:)`.
///
/// On passe à la source suivante sur ERREUR comme sur ZÉRO résultat : une instance SearXNG dont
/// les moteurs sont bloqués répond « 200, aucun résultat », et une clé épuisée lève `.rateLimited` ;
/// dans les deux cas, la source suivante a ses chances.
///
/// ACADÉMIQUE ET DISCUSSION : l'étape SearXNG force les moteurs (`arxiv`, `google scholar`,
/// `pubmed` ; `reddit`) puis, si la réponse est VIDE, relance la recherche web générale sur
/// SearXNG : c'est le repli du bug 5, déplacé dans la chaîne quand elle est branchée
/// (`SearXNGWithWebFallbackStep`). Le placer DANS l'étape SearXNG, plutôt qu'en relançant toute la
/// chaîne en général à la fin, fait passer la recherche générale, gratuite, AVANT la recherche
/// cloud, payante, et n'use pas deux fois le quota d'une clé personnelle. Brave, Tavily et le
/// cloud ignorent la catégorie (moteurs généralistes) ; les sources ouvertes ont leur ordre propre.
///
/// LANGUE : `language == nil` (le cas de l'app) ne convient pas à toutes les sources. Wikipédia
/// retombe alors sur `en.wikipedia.org` et Brave sur son défaut anglais ; or la chaîne s'arrête à
/// la première réponse NON VIDE, et le Wikipédia anglais répond à une question française par du
/// hors-sujet non vide (mesuré le 2026-11-04 : « Quelle est la hauteur de la tour Eiffel ? » donne
/// « List of Quebec films », contre « Tour Eiffel » sur `fr`) : cette page deviendrait la source
/// citée. Quand l'appelant n'impose pas de langue, on détecte donc celle du texte envoyé (la
/// reformulation, c'est lui que la source compare à son index) ; sous le seuil de confiance (noms
/// propres, mots isolés : « Marie Curie », « Tour Eiffel »), on prend `fallbackLanguage`, la langue
/// de l'appareil. Reçoivent cette langue : les clés personnelles et les sources ouvertes.
/// Gardent les options de l'appelant (`usesDetectedLanguage`) :
/// - SearXNG : parité avec le chemin sans chaîne (langue laissée à l'instance). Y imposer la
///   langue retirerait les sources de l'autre langue du classement, arbitrage réservé à Ben ;
/// - le cloud : Perplexity traduit la langue en `search_language_filter`, un filtre STRICT et non
///   un indice, sur l'étape payante.
///
/// RÉSULTAT : la réponse ET la source qui l'a fournie (`WebSearchChainResult.source`), pour dire
/// honnêtement à l'utilisateur d'où viennent les sources affichées.
/// - Toutes les sources ont LEVÉ : `WebSearchChainError.allSourcesFailed`, un motif par source.
///   Rien n'a marché, l'utilisateur doit le savoir : le chat affiche alors une invitation à
///   ajouter une clé de recherche (`SearchKeyInvitation`).
/// - Au moins une a RÉPONDU, toutes à vide : réponse vide, source = la dernière qui a répondu.
///   Ce n'est pas un échec, la question n'a simplement aucun résultat ; le prompt de rédaction
///   le dit déjà (« Aucune source disponible. »).
///
/// ANNULATION : vérifiée avant CHAQUE source, donc avant la recherche cloud payante, et une
/// erreur d'annulation n'est jamais comptée comme un échec de source (même critère que
/// l'orchestrateur, `SearchOrchestrator.isCancellation`). Sinon l'appui sur Stop ferait passer à
/// la source suivante, parfois payante, au lieu d'arrêter.
///
/// SECRETS : ni clé ni question de l'utilisateur dans le journal, seulement la source et le motif
/// (cas de `WebSearchError`, à messages fixes). Les providers ne lèvent que des `WebSearchError`
/// (contrat de `WebSearchProviding`) ; une autre erreur vaut `.unavailable`, jamais son texte.
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search`, règle du projet pour l'orchestration ;
/// chaque provider porte déjà son propre `@concurrent` pour le réseau et le décodage.
nonisolated struct WebSearchChain: Sendable {
    /// Résultats demandés à chaque source. 50 : au-delà d'une page SearXNG ordinaire (une dizaine
    /// de résultats par moteur actif, fusionnés), donc pas de troncature en pratique. C'est la
    /// parité avec le chemin historique, qui donnait la page ENTIÈRE à `SourceRanker` : un vivier
    /// tronqué à 10 (défaut de `WebSearchOptions`) ferait choisir les sources parmi 2 à 3 fois
    /// moins de candidats, et le mode Fiable, qui filtre les domaines AVANT le score, répondrait
    /// bien plus souvent « Aucune source fiable ». Chaque source borne elle-même (Brave, Tavily,
    /// Wikipédia, Perplexity : 20 ; arXiv : 50 ; OpenAlex, Marginalia : 100) : jamais de requête
    /// refusée pour un plafond trop haut.
    static let maxResultsPerSource = 50

    /// Journal de la chaîne et de son assemblage (`WebSearchChain+Assembly.swift`) : source et
    /// motif seulement, jamais de clé ni de question.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "WebSearchChain"
    )

    private let keyedProviders: [any WebSearchProviding]
    private let searxng: (any WebSearchProviding)?
    private let cloudProvider: (any WebSearchProviding)?
    private let openSourceProviders: @Sendable (WebSearchCategory) -> [any WebSearchProviding]
    private let unreadableKeySources: [WebSearchSourceKind]
    private let languageIdentifier: any TextLanguageIdentifying
    private let fallbackLanguage: String?

    /// - Parameters:
    ///   - keyedProviders: sources à clé personnelle, dans l'ordre de préférence.
    ///   - searxng: SearXNG sur le `FailoverManager` de la session, enveloppé ici dans l'étape à
    ///     repli web (académique, discussion). `nil` : étape absente.
    ///   - cloudProvider: recherche du fournisseur IA cloud actif, `nil` hors moteur cloud.
    ///   - openSourceProviders: sources ouvertes à essayer pour une catégorie, dans l'ordre.
    ///   - unreadableKeySources: sources dont la clé n'a pas pu être lue dans le trousseau
    ///     (`assemble`). Jamais interrogées, mais comptées comme échecs `.keychainUnreadable` :
    ///     un trousseau illisible ne doit ni bloquer la recherche ni disparaître en silence.
    ///   - languageIdentifier: détection de la langue de la question (voir « LANGUE »).
    ///   - fallbackLanguage: langue à utiliser quand la détection ne tranche pas, `nil` : aucune.
    init(
        keyedProviders: [any WebSearchProviding] = [],
        searxng: (any WebSearchProviding)?,
        cloudProvider: (any WebSearchProviding)? = nil,
        openSourceProviders: @escaping @Sendable (WebSearchCategory) -> [any WebSearchProviding],
        unreadableKeySources: [WebSearchSourceKind] = [],
        languageIdentifier: any TextLanguageIdentifying = NaturalLanguageTextIdentifier(),
        fallbackLanguage: String? = nil
    ) {
        self.keyedProviders = keyedProviders
        self.searxng = searxng
        self.cloudProvider = cloudProvider
        self.openSourceProviders = openSourceProviders
        self.unreadableKeySources = unreadableKeySources
        self.languageIdentifier = languageIdentifier
        self.fallbackLanguage = fallbackLanguage
    }

    /// Même chaîne, sources ouvertes fournies par `OpenSourceSearchChain` (forme de l'app).
    init(
        keyedProviders: [any WebSearchProviding] = [],
        searxng: (any WebSearchProviding)?,
        cloudProvider: (any WebSearchProviding)? = nil,
        openSources: OpenSourceSearchChain = OpenSourceSearchChain(),
        unreadableKeySources: [WebSearchSourceKind] = [],
        languageIdentifier: any TextLanguageIdentifying = NaturalLanguageTextIdentifier(),
        fallbackLanguage: String? = nil
    ) {
        self.init(
            keyedProviders: keyedProviders,
            searxng: searxng,
            cloudProvider: cloudProvider,
            openSourceProviders: { openSources.providers(for: $0) },
            unreadableKeySources: unreadableKeySources,
            languageIdentifier: languageIdentifier,
            fallbackLanguage: fallbackLanguage
        )
    }

    /// Sources à essayer, dans l'ordre, pour une catégorie.
    func providers(for category: WebSearchCategory) -> [any WebSearchProviding] {
        let searxngStep: [any WebSearchProviding] = searxng.map { [SearXNGWithWebFallbackStep(base: $0)] } ?? []
        let cloudStep: [any WebSearchProviding] = cloudProvider.map { [$0] } ?? []
        return keyedProviders + searxngStep + cloudStep + openSourceProviders(category)
    }

    /// Ordre d'essai pour une catégorie, sans aucune requête (tests, futur affichage).
    func kinds(for category: WebSearchCategory) -> [WebSearchSourceKind] {
        providers(for: category).map { $0.kind }
    }

    /// Essaie les sources dans l'ordre jusqu'à la première réponse NON VIDE.
    ///
    /// Lève `WebSearchChainError.allSourcesFailed` si toutes ont levé, `CancellationError` si la
    /// tâche est annulée ; jamais d'autre erreur.
    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> WebSearchChainResult {
        var failures = unreadableKeySources.map { WebSearchSourceFailure(source: $0, reason: .keychainUnreadable) }
        var lastEmptyAnswer: WebSearchChainResult?
        let localized = localizedOptions(options, query: query)
        for provider in providers(for: options.category) {
            try Task.checkCancellation()
            let kind = provider.kind
            do {
                let response = try await provider.search(
                    query: query,
                    options: Self.usesDetectedLanguage(kind) ? localized : options
                )
                let answer = WebSearchChainResult(response: response, source: kind)
                guard response.results.isEmpty else { return answer }
                Self.logger.info("Recherche web : \(kind.rawValue, privacy: .public) sans résultat, source suivante")
                lastEmptyAnswer = answer
            } catch {
                if SearchOrchestrator.isCancellation(error) { throw CancellationError() }
                let reason = WebSearchSourceFailure.Reason.searchFailed((error as? WebSearchError) ?? .unavailable)
                Self.logger.info(
                    "Recherche web : \(kind.rawValue, privacy: .public) en échec (\(String(describing: reason), privacy: .public)), source suivante"
                )
                failures.append(WebSearchSourceFailure(source: kind, reason: reason))
            }
        }
        if let lastEmptyAnswer { return lastEmptyAnswer }
        throw WebSearchChainError.allSourcesFailed(failures)
    }

    /// Options avec la langue de la question (voir « LANGUE ») ; une langue imposée par
    /// l'appelant passe telle quelle.
    private func localizedOptions(_ options: WebSearchOptions, query: String) -> WebSearchOptions {
        guard options.language == nil else { return options }
        return WebSearchOptions(
            language: languageIdentifier.dominantLanguage(of: query) ?? fallbackLanguage,
            category: options.category,
            maxResults: options.maxResults
        )
    }

    /// Sources qui reçoivent la langue détectée (voir « LANGUE »). Énumération exhaustive exprès :
    /// une nouvelle source devra choisir.
    private static func usesDetectedLanguage(_ kind: WebSearchSourceKind) -> Bool {
        switch kind {
        case .braveSearch, .tavily, .wikipedia, .openAlex, .arXiv, .marginalia: true
        case .searxng, .cloudProviderWebSearch: false
        }
    }
}

// MARK: - Résultat et erreurs

/// Réponse retenue par la chaîne et source qui l'a fournie.
nonisolated struct WebSearchChainResult: Sendable, Equatable {
    let response: SearXNGSearchResponse
    let source: WebSearchSourceKind
}

/// Échec d'une source de la chaîne. Ni clé, ni corps de réponse, ni URL : la source et un motif.
nonisolated struct WebSearchSourceFailure: Sendable, Equatable {
    nonisolated enum Reason: Sendable, Equatable {
        /// Source interrogée, en échec (message fixe de `WebSearchError`).
        case searchFailed(WebSearchError)
        /// Clé de la source illisible dans le trousseau : source jamais interrogée.
        case keychainUnreadable
    }

    let source: WebSearchSourceKind
    let reason: Reason
}

/// Erreur de la chaîne de repli.
///
/// `CustomStringConvertible`, `description` = `userFacingMessage` : le bandeau passe par
/// `ChatViewModel+ErrorMessages.swift`, qui gère ce type ; `description` n'est qu'une sécurité
/// pour tout autre affichage, qui montrerait sinon `allSourcesFailed([…])`, un nom technique
/// en anglais. Le texte reste fixe : les motifs ne
/// portent rien qui vienne du réseau, mais ils n'y sont pas recopiés pour autant.
nonisolated enum WebSearchChainError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Toutes les sources essayées ont levé une erreur, aucune n'a répondu (même à vide). Un
    /// motif par source, dans l'ordre : d'abord les clés illisibles, puis l'ordre d'essai.
    case allSourcesFailed([WebSearchSourceFailure])

    var userFacingMessage: String {
        switch self {
        case .allSourcesFailed:
            "Aucune source de recherche n'a répondu. Vérifie ta connexion, puis réessaie."
        }
    }

    var description: String { userFacingMessage }
}

// MARK: - Étape SearXNG

/// Étape SearXNG de la chaîne : en académique ou discussion, moteurs forcés puis, si la réponse
/// est VIDE, recherche web générale sur les mêmes instances (repli du bug 5, voir la
/// documentation de `WebSearchChain`). Une ERREUR, elle, ne déclenche pas ce second appel : quand
/// toutes les instances ont échoué, les réinterroger en général doublerait l'attente (jusqu'à
/// 10 s par instance) pour le même échec, et la chaîne passe directement à la source suivante.
/// Une erreur du second appel remonte comme une erreur de l'étape.
private nonisolated struct SearXNGWithWebFallbackStep: WebSearchProviding {
    let base: any WebSearchProviding

    var kind: WebSearchSourceKind { base.kind }

    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        let response = try await base.search(query: query, options: options)
        guard response.results.isEmpty, options.category != .general else { return response }
        try Task.checkCancellation()
        let generalOptions = WebSearchOptions(
            language: options.language,
            category: .general,
            maxResults: options.maxResults
        )
        return try await base.search(query: query, options: generalOptions)
    }
}
