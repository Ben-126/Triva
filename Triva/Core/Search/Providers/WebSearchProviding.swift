//
//  WebSearchProviding.swift
//  Triva
//
//  Created by ben podrojsky on 08/10/2026.
//

import Foundation

/// Contrat commun à toutes les sources de recherche web de Triva (décision de Ben du
/// 2026-10-08 : quatre sources de secours, toutes en V1, pour ne jamais dépendre des seules
/// instances SearXNG publiques, dont la plupart bloquent désormais les clients sans JavaScript).
///
/// Chaîne de repli prévue (câblée dans l'orchestrateur à l'intégration) :
/// 1. clé de recherche personnelle (Brave / Tavily / Google Programmable Search) si présente ;
/// 2. SearXNG (instances testées et classées par fiabilité) ;
/// 3. recherche web intégrée du fournisseur IA cloud, si l'utilisateur en a une clé ;
/// 4. sources ouvertes sans clé (Wikipédia, OpenAlex, arXiv, Marginalia).
///
/// Les résultats réutilisent `SearXNGSearchResponse` / `SearXNGSearchResult` : c'est le type
/// que tout le pipeline (classement, prompt, citations, affichage des sources) consomme déjà,
/// une source de plus ne doit donc rien changer en aval.
nonisolated protocol WebSearchProviding: Sendable {
    /// Source utilisée, pour dire honnêtement à l'utilisateur d'où viennent les résultats.
    var kind: WebSearchSourceKind { get }

    /// Lance une recherche. Ne lève que des `WebSearchError` (messages fixes, jamais de clé
    /// ni d'URL contenant une clé). Doit respecter l'annulation de la `Task` appelante.
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse
}

/// D'où viennent les résultats affichés.
nonisolated enum WebSearchSourceKind: String, Sendable, Equatable, CaseIterable, Codable {
    case braveSearch
    case tavily
    case googleProgrammableSearch
    case searxng
    case cloudProviderWebSearch
    case wikipedia
    case openAlex
    case arXiv
    case marginalia

    /// Libellé court, en français, affichable à l'utilisateur.
    var displayName: String {
        switch self {
        case .braveSearch: "Brave Search"
        case .tavily: "Tavily"
        case .googleProgrammableSearch: "Google"
        case .searxng: "SearXNG"
        case .cloudProviderWebSearch: "Recherche du fournisseur IA"
        case .wikipedia: "Wikipédia"
        case .openAlex: "OpenAlex"
        case .arXiv: "arXiv"
        case .marginalia: "Marginalia"
        }
    }
}

/// Paramètres communs, volontairement minimaux : chaque source traduit ce qu'elle sait faire.
nonisolated struct WebSearchOptions: Sendable, Equatable {
    /// Code langue BCP 47 court (« fr », « en »), `nil` = laisser la source décider.
    var language: String?
    var category: WebSearchCategory
    /// Plafond de résultats demandés (les sources peuvent en renvoyer moins).
    var maxResults: Int

    init(language: String? = nil, category: WebSearchCategory = .general, maxResults: Int = 10) {
        self.language = language
        self.category = category
        self.maxResults = maxResults
    }
}

/// Type de recherche demandé par la classification de la requête.
nonisolated enum WebSearchCategory: String, Sendable, Equatable, CaseIterable {
    case general
    case academic
    case discussion
}

/// Erreurs communes. Messages fixes en français : aucune clé, aucune URL, aucun corps de
/// réponse ne doit jamais y apparaître.
nonisolated enum WebSearchError: Error, Sendable, Equatable {
    /// Pas de clé enregistrée pour une source qui en exige une.
    case missingKey
    /// Clé refusée (401/403).
    case unauthorized
    /// Quota ou limite de débit atteint (429).
    case rateLimited
    /// Source indisponible (5xx, réseau, aucune instance utilisable).
    case unavailable
    /// Réponse illisible ou format inattendu.
    case invalidResponse
    case timeout
    /// Cette source ne sait pas traiter cette catégorie (ex. arXiv pour une question générale).
    case unsupportedCategory

    var userFacingMessage: String {
        switch self {
        case .missingKey: "Aucune clé de recherche n'est enregistrée pour ce service."
        case .unauthorized: "La clé de recherche a été refusée."
        case .rateLimited: "La limite de recherches de ce service est atteinte pour le moment."
        case .unavailable: "Ce service de recherche ne répond pas."
        case .invalidResponse: "La réponse du service de recherche est illisible."
        case .timeout: "Le service de recherche a mis trop de temps à répondre."
        case .unsupportedCategory: "Ce service ne couvre pas ce type de recherche."
        }
    }
}
