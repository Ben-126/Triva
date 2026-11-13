//
//  MediaSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

/// Médias que l'appelant demande AVEC la réponse (1.6). Vide par défaut : une
/// recherche média coûte deux requêtes SearXNG de plus par question, sur des
/// instances publiques souvent limitées en débit. C'est l'appelant qui
/// choisit (recherche systématique, ou à la demande via `ImageSearchService`
/// et `VideoSearchService` comme le bouton de la version web d'origine).
nonisolated struct MediaSearchKinds: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let images = MediaSearchKinds(rawValue: 1 << 0)
    static let videos = MediaSearchKinds(rawValue: 1 << 1)
    static let all: MediaSearchKinds = [.images, .videos]
}

/// Issue d'une recherche média, prête à être traduite en phase d'affichage
/// (`ImageResultsPhase`, `VideoResultsPhase`) : `.notRequested` -> `.idle`,
/// `.found` -> `.loaded`, `.failed` -> `.failed`.
///
/// Aucun détail d'erreur, exprès : une erreur réseau n'apporte rien à
/// l'utilisateur ici (le texte de la réponse, lui, est là), et `.failed`
/// suffit à proposer de relancer la recherche.
nonisolated enum MediaSearchOutcome<Item: Sendable>: Sendable {
    /// Non demandée, ou aucune recherche web pour ce message (calcul,
    /// salutation, question sur un fichier joint).
    case notRequested
    /// La recherche a abouti ; le tableau peut être vide.
    case found([Item])
    /// SearXNG indisponible, ou résultat arrivé trop tard (voir
    /// `SearchOrchestrator.defaultMediaGracePeriod`).
    case failed

    /// Les résultats, ou un tableau vide hors `.found`.
    var items: [Item] {
        switch self {
        case .found(let items): items
        case .notRequested, .failed: []
        }
    }
}

/// Images et vidéos d'une même question.
nonisolated struct MediaSearchResults: Sendable {
    let images: MediaSearchOutcome<ImageSearchResult>
    let videos: MediaSearchOutcome<VideoSearchResult>

    static let notRequested = MediaSearchResults(images: .notRequested, videos: .notRequested)

    /// Toutes les recherches demandées en échec, les autres non demandées.
    static func failed(_ kinds: MediaSearchKinds) -> MediaSearchResults {
        MediaSearchResults(
            images: kinds.contains(.images) ? .failed : .notRequested,
            videos: kinds.contains(.videos) ? .failed : .notRequested
        )
    }

    /// Lance les recherches demandées EN PARALLÈLE l'une de l'autre. Ne lève
    /// jamais : un échec devient `.failed`, la réponse texte n'en dépend pas.
    /// Une annulation produit aussi `.failed` ici ; c'est la recherche texte,
    /// menée à côté, qui la propage (`SearchOrchestrator`).
    static func search(_ kinds: MediaSearchKinds, query: String, using searcher: any MediaSearching) async -> MediaSearchResults {
        async let images = imageOutcome(requested: kinds.contains(.images), query: query, searcher: searcher)
        async let videos = videoOutcome(requested: kinds.contains(.videos), query: query, searcher: searcher)
        return MediaSearchResults(images: await images, videos: await videos)
    }

    private static func imageOutcome(
        requested: Bool,
        query: String,
        searcher: any MediaSearching
    ) async -> MediaSearchOutcome<ImageSearchResult> {
        guard requested else { return .notRequested }
        do {
            return .found(try await searcher.searchImages(query: query))
        } catch {
            return .failed
        }
    }

    private static func videoOutcome(
        requested: Bool,
        query: String,
        searcher: any MediaSearching
    ) async -> MediaSearchOutcome<VideoSearchResult> {
        guard requested else { return .notRequested }
        do {
            return .found(try await searcher.searchVideos(query: query))
        } catch {
            return .failed
        }
    }
}

/// Recherche média injectable (tests), sur une requête DÉJÀ autonome.
nonisolated protocol MediaSearching: Sendable {
    func searchImages(query: String) async throws -> [ImageSearchResult]
    func searchVideos(query: String) async throws -> [VideoSearchResult]
}

/// Recherche média du pipeline : SearXNG interrogé avec la reformulation du
/// classifieur (`SearchOrchestrator.effectiveQuery`), puis le filtrage des
/// services de 1.6 (`filterAndMap` : `https` strict, titre non vide, 10
/// résultats).
///
/// Pourquoi pas `ImageSearchService.search` / `VideoSearchService.search` :
/// chacun commence par un appel LLM de reformulation
/// (`MediaSearchQueryReformulator`), qui refait exactement ce que le
/// classifieur vient de faire (`standaloneFollowUp`). Deux appels LLM de plus
/// par question, et, sur MLX (un `actor`), deux générations en file devant
/// le planner et la réponse. Ces services restent la voie de la recherche À
/// LA DEMANDE, hors pipeline.
///
/// Limite assumée : les options SearXNG (catégories et moteurs) sont
/// recopiées de ces services, qui les écrivent en ligne. Les deux copies
/// doivent évoluer ensemble.
nonisolated struct SearXNGMediaSearcher: MediaSearching {
    static let imageSearchOptions = SearXNGSearchOptions(categories: ["images"], engines: ["bing images", "google images"])
    static let videoSearchOptions = SearXNGSearchOptions(categories: ["videos"], engines: ["youtube"])
    /// `.slice(0, 10)` de la version web d'origine, comme les services de 1.6.
    static let defaultMaxResults = 10

    private let failoverManager: FailoverManager
    private let maxResults: Int

    init(failoverManager: FailoverManager, maxResults: Int = SearXNGMediaSearcher.defaultMaxResults) {
        self.failoverManager = failoverManager
        self.maxResults = maxResults
    }

    func searchImages(query: String) async throws -> [ImageSearchResult] {
        let response = try await failoverManager.search(query: query, options: Self.imageSearchOptions)
        return await ImageSearchService.filterAndMap(response.results, maxResults: maxResults)
    }

    func searchVideos(query: String) async throws -> [VideoSearchResult] {
        let response = try await failoverManager.search(query: query, options: Self.videoSearchOptions)
        return await VideoSearchService.filterAndMap(response.results, maxResults: maxResults)
    }
}
