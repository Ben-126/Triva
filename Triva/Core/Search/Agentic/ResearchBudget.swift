//
//  ResearchBudget.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation

/// Plafonds de l'enquête menée par l'IA (tâche 2.4, spec §2.1). Appliqués par CODE
/// (`ResearchLedger`) : une page lue peut contenir une injection de prompt, les
/// instructions du modèle ne suffisent pas à borner ses appels d'outil.
///
/// Mesures du prototype M1 (W3-A1) : l'enquête Approfondie complète tient en ~1 600
/// tokens de contexte (fenêtre de 8 192 sur l'appareil, 4-8K selon la source), sous le
/// seuil de 3 000 de la spec : les budgets du tableau de la spec §2.1 restent donc inchangés.
nonisolated struct ResearchBudget: Sendable, Equatable {
    /// Recherches de l'enquêteur, EN PLUS de la recherche de départ du code.
    let maxSearches: Int
    /// Pages lues (tentatives : un échec de lecture consomme aussi).
    let maxReads: Int
    /// Appels d'outil au total (recherches, lectures, requêtes en double, numéros inconnus…).
    /// `finish` n'y compte jamais.
    let maxToolCalls: Int
    /// Délai total de l'enquête, appliqué par l'appelant (`TaskGroup`, mission M3).
    let timeout: Duration

    /// Aucun enquêteur : le mode Rapide garde la boucle actuelle.
    static let disabled = ResearchBudget(maxSearches: 0, maxReads: 0, maxToolCalls: 0, timeout: .zero)

    /// Faux si le mode n'a pas d'enquêteur (budget nul).
    var isEnabled: Bool { maxToolCalls > 0 }

    /// Budget du mode (spec §2.1) :
    ///
    /// | Mode | Recherches | Pages lues | Appels | Délai |
    /// |---|---|---|---|---|
    /// | Rapide | aucun enquêteur | | | |
    /// | Approfondie | 2 | 4 | 8 | 30 s |
    /// | Fiable | 2 | 3 | 6 | 25 s |
    ///
    /// Les pages lues sont plafonnées à `configuration.maxResultsUsedForContext` : une page
    /// lue doit pouvoir figurer parmi les sources affichées (`pagesBackedBySources`).
    /// `switch` sur les cas, jamais de propriété de `ResponseMode` (type isolé au main actor :
    /// cette fonction reste utilisable depuis l'orchestrateur, hors du main actor).
    static func `for`(mode: ResponseMode, configuration: SearchPipelineConfiguration) -> ResearchBudget {
        let reads: Int
        let base: ResearchBudget
        switch mode {
        case .quick:
            return .disabled
        case .deep:
            reads = 4
            base = ResearchBudget(maxSearches: 2, maxReads: reads, maxToolCalls: 8, timeout: .seconds(30))
        case .reliable:
            reads = 3
            base = ResearchBudget(maxSearches: 2, maxReads: reads, maxToolCalls: 6, timeout: .seconds(25))
        }
        let cappedReads = max(0, min(reads, configuration.maxResultsUsedForContext))
        return ResearchBudget(
            maxSearches: base.maxSearches,
            maxReads: cappedReads,
            maxToolCalls: base.maxToolCalls,
            timeout: base.timeout
        )
    }
}
