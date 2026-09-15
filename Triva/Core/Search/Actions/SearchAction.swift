//
//  SearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Sortie unifiée d'une action de recherche, consommée par la boucle
/// d'orchestration (`SearchOrchestrator`) sans qu'elle ait besoin de connaître
/// le type concret de l'action exécutée. Port de la diversité des objets
/// renvoyés par `ResearchAction.execute()` (web, `{type: 'search_results' |
/// 'reasoning' | 'done', ...}`) — ici un `enum` Swift à la place d'un
/// discriminant `type` en chaîne.
enum SearchActionOutput: Sendable {
    case searchResults([SearXNGSearchResult])
    case scrapedPages([ScrapedPage])
    case reasoning(String)
    case done
}

/// Port de `ResearchAction` (web, `researcher/actions/types.ts`) : une action
/// exécutable par la boucle d'orchestration. Contrairement à la référence web
/// (schéma zod + tool-calling natif exposé au LLM), chaque action Swift est
/// sélectionnée par nom depuis `SearchOrchestrator` via un parsing JSON
/// tolérant (`decideNextAction`) — aucun des 3 providers IA de Triva
/// n'expose un function-calling fiable (voir `QueryClassifier`, qui fait déjà
/// ce même choix pour la même raison), donc le LLM ne "choisit" jamais
/// directement un outil au sens Playwright/OpenAI du terme.
protocol SearchAction: Sendable {
    /// Nom stable de l'action : identifie l'action dans la boucle
    /// d'orchestration ET dans le prompt du planner (itérations 2+).
    var name: String { get }

    /// Description destinée au prompt du planner : explique en langage
    /// naturel QUAND choisir cette action.
    var descriptionForPlanner: String { get }

    /// Signature commune à toutes les actions plutôt que des protocoles
    /// séparés par catégorie (recherche / scraping / méta) : `urls` n'a de
    /// sens que pour une action de scraping (ignoré par les actions de
    /// recherche), `query` n'a de sens que pour une action de recherche
    /// (ignoré par le scraping, qui n'agit que sur `urls`) — la checklist du
    /// plan demande explicitement "un protocole SearchAction avec une
    /// implémentation par type d'action", et la boucle d'orchestration doit
    /// pouvoir appeler n'importe quelle action sans connaître sa catégorie.
    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput
}
