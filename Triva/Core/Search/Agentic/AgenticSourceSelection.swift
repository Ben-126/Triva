//
//  AgenticSourceSelection.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation

/// Assemblage PUR des sources finales après l'enquête (spec 2.4 §2.4). Le classement
/// (`SourceRanker.rank`, asynchrone) est fait par l'appelant sur `union(seeded:found:)` et rendu ici
/// dans `ranked` : cette fonction ne fait que placer, filtrer et borner.
nonisolated enum AgenticSourceSelection {
    /// Sources à afficher (ordre = numérotation des citations) et pages à injecter dans le prompt.
    nonisolated struct Selection: Sendable, Equatable {
        let sources: [SearXNGSearchResult]
        let pages: [ScrapedPage]
    }

    /// Départ puis résultats de l'enquêteur, dans l'ordre d'arrivée, dédupliqués par `urlKey`
    /// (la première occurrence gagne). Entrée de `SourceRanker.rank`, dont 30 % du score dérive de la position.
    static func union(seeded: [SearXNGSearchResult], found: [SearXNGSearchResult]) -> [SearXNGSearchResult] {
        var seenKeys: Set<String> = []
        return (seeded + found).filter { seenKeys.insert(SearchOrchestrator.urlKey($0.url)).inserted }
    }

    /// 1. Pages lues AVEC succès en tête, dans l'ordre de lecture : sans cela, `pagesBackedBySources`
    ///    jetterait toute page absente du classement. Une page lue dont l'URL n'est ni dans le départ ni
    ///    dans les résultats trouvés n'est pas « appuyée » par une source : écartée. Bornées par `limit`.
    /// 2. Puis le classement `ranked`, sans doublon, jusqu'à `limit` sources.
    /// 3. Mode Fiable (`trustedDomainsOnly`) : le prédicat `SourceRanker.isTrustedDomain` est réappliqué
    ///    ICI, aux pages lues comme au classement : `seededWebSearch` ne filtre que la chaîne (SearXNG seul
    ///    rend tout), une page non fiable ne doit jamais remonter en tête.
    /// 4. `pages` : TOUTES les pages tentées (échecs et refus compris, comme la boucle actuelle) dont la
    ///    source a été retenue, l'URL réécrite sur celle de la source (`pagesBackedBySources`).
    static func finalSources(
        seeded: [SearXNGSearchResult],
        found: [SearXNGSearchResult],
        readPages: [ScrapedPage],
        ranked: [SearXNGSearchResult],
        limit: Int,
        trustedDomainsOnly: Bool
    ) -> Selection {
        guard limit > 0 else { return Selection(sources: [], pages: []) }
        let candidates = union(seeded: seeded, found: found)
        let candidateByKey = Dictionary(
            candidates.map { (SearchOrchestrator.urlKey($0.url), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sources: [SearXNGSearchResult] = []
        var placedKeys: Set<String> = []

        func place(_ result: SearXNGSearchResult) {
            guard sources.count < limit else { return }
            guard !trustedDomainsOnly || SourceRanker.isTrustedDomain(result.url) else { return }
            guard placedKeys.insert(SearchOrchestrator.urlKey(result.url)).inserted else { return }
            sources.append(result)
        }

        for page in readPages where page.succeeded && !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let source = candidateByKey[SearchOrchestrator.urlKey(page.url)] { place(source) }
        }
        ranked.forEach(place)
        return Selection(sources: sources, pages: SearchOrchestrator.pagesBackedBySources(readPages, sources: sources))
    }
}
