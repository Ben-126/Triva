//
//  SearchOrchestrator+PreRead.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

/// Lecture SANS LLM des sources retenues qui n'ont aucun extrait (mission A1,
/// décision (a) de Ben du 2026-11-10), dans TOUS les modes, mode Rapide compris.
///
/// Pourquoi : le repli cloud de la recherche (`CloudWebSearchProvider`) rend des
/// sources sans texte — OpenAI ne donne que des URL (`url_citation`,
/// `action.sources`), Gemini des segments de SA réponse, que l'app n'utilise plus
/// comme extrait. Le mode Rapide n'ayant pas de planner, rien ne lisait ces
/// pages : rapport T2, scénario t7, une réponse écrite de tête et citée
/// [2][3][4] sur des pages jamais lues. Cette lecture leur donne un contenu ;
/// celles qu'elle ne parvient pas à lire deviennent non citables
/// (`PromptTemplates.numberedContext`), jamais renumérotées.
///
/// Écart assumé avec la version web d'origine : là-bas, toute lecture de
/// page est une décision du modèle. Ici, une source sans extrait n'a rien à
/// offrir au rédacteur ; la lire n'est pas un choix, c'est la condition pour
/// qu'elle compte. Aucun appel au modèle n'est fait pour cela.
///
/// Toutes ces sources sont lues, sans le plafond `maxScrapedURLsPerIteration`
/// du planner : elles sont au plus `maxResultsUsedForContext` (3 en Rapide, 5
/// sinon), lues en parallèle sous UNE échéance commune (`scrapeAll`), et une
/// source non lue est perdue pour la réponse.
///
/// Le tour seedé ne rend aujourd'hui aucune page (aucune action ne produit
/// `SearchActionOutput.scrapedPages`) : une source déjà lue par lui serait
/// relue ici, ce qui coûterait une requête, jamais une citation fausse.
extension SearchOrchestrator {
    /// Échéance de la lecture en mode Rapide : `ScrapeService.defaultIdleTimeout`
    /// (8 s), la durée au-delà de laquelle le service abandonne déjà une page
    /// silencieuse. Rapide promet une réponse vite : il ne paie pas l'échéance
    /// complète d'un tour du planner (`defaultScrapeRoundTimeout`, 15 s). Une
    /// page lente perdue n'est pas citée, elle n'est jamais citée à tort.
    /// À VALIDER PAR BEN (valeur choisie par la mission A1).
    nonisolated static let quickPreReadTimeout: Duration = .seconds(8)

    /// Échéance de la lecture : la plus courte de `quickPreReadTimeout` et de
    /// l'échéance injectée en mode Rapide (un test qui la raccourcit doit être
    /// suivi), l'échéance d'un tour du planner dans les autres modes, qui
    /// acceptent déjà de lire des pages pendant ce temps.
    nonisolated static func preReadTimeout(for mode: ResponseMode, scrapeRoundTimeout: Duration) -> Duration {
        guard case .quick = mode else { return scrapeRoundTimeout }
        return min(scrapeRoundTimeout, quickPreReadTimeout)
    }

    /// URLs des sources dont l'extrait est absent ou blanc, dans l'ordre des
    /// sources (celui des citations), une fois chacune (clé `urlKey`, celle du
    /// dédoublonnage). Même critère de vide que
    /// `PromptTemplates.numberedContext`, qui omet ces sources si elles restent
    /// sans contenu.
    nonisolated static func sourcesWithoutExcerpt(_ sources: [SearXNGSearchResult]) -> [String] {
        var seenKeys: Set<String> = []
        return sources
            .filter { ($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.url)
            .filter { seenKeys.insert(urlKey($0)).inserted }
    }

    /// Lit `sourcesWithoutExcerpt(sources)` en UN tour de scrape (`scrapeAll` :
    /// parallèle, échéance globale, pages rendues dans l'ordre, échec = page en
    /// échec, jamais d'erreur), puis vérifie l'annulation (Stop) : `scrapeAll` ne
    /// lève jamais. Aucune source sans extrait : aucun appel, l'horloge n'est pas
    /// lue.
    ///
    /// Statique, avec service, échéance et horloge en paramètres : sans instance
    /// d'orchestrateur, les tests lisent des pages avec une horloge et un scrape
    /// injectés, et l'exécution reste hors du main actor (les propriétés stockées
    /// utiles sont internes depuis le découpage E1, ce n'est plus une contrainte).
    /// `nonisolated` explicite, comme tout membre d'extension de ce type : sans
    /// annotation, l'isolation par défaut du projet (main actor) s'appliquerait.
    nonisolated static func preRead<C: Clock<Duration>>(
        _ sources: [SearXNGSearchResult],
        using scrapeService: any ScrapeServing,
        timeout: Duration,
        clock: C
    ) async throws -> [ScrapedPage] {
        let urls = sourcesWithoutExcerpt(sources)
        guard !urls.isEmpty else { return [] }
        let pages = await scrapeAll(urls, using: scrapeService, timeout: timeout, clock: clock)
        try Task.checkCancellation()
        return pages
    }
}
