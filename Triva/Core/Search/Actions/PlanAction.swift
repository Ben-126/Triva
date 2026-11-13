//
//  PlanAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de l'action `__reasoning_preamble` de la version web d'origine : malgré son nom
/// (« plan »), ce n'est PAS un planificateur algorithmique — dans la version web d'origine, c'est un
/// outil de plus dans le registre, sans aucun effet de bord réel
/// (`execute()` renvoie juste `{type: 'reasoning', reasoning: input.plan}`),
/// qui sert uniquement à exposer le raisonnement du LLM dans l'UI de
/// recherche. La vraie décision "quelle action lancer ensuite" appartient à
/// `SearchOrchestrator.decideNextAction`, jamais à cette action elle-même.
///
/// `SearchOrchestrator` ne câble PAS `PlanAction` dans sa boucle planner
/// (`SearchOrchestrator.plannerActionNames` ne propose que `scrapeURL`,
/// `uploadsSearch` depuis 1.11, et `done` — une UI "recherche en cours"
/// façon version web d'origine est hors scope).
/// Ce type existe pour satisfaire "un protocole SearchAction avec une
/// implémentation par type d'action" et rester testable isolément, pas parce
/// qu'un appelant réel l'invoque aujourd'hui.
struct PlanAction: SearchAction {
    let name = "plan"
    let descriptionForPlanner = "Expose un raisonnement libre avant de choisir une action réelle — n'effectue aucune recherche, aucun effet de bord."

    /// `query` porte ici le texte de raisonnement à renvoyer tel quel (seul
    /// paramètre texte disponible dans la signature commune de
    /// `SearchAction`) — simple passthrough, comme dans la version web d'origine.
    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        .reasoning(query)
    }
}
