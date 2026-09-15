//
//  DoneAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port fidèle de `done.ts` (web) : registrée pour complétude (le nom
/// "done" est exposé au planner dans `SearchOrchestrator.plannerPrompt`),
/// mais son `execute()` n'est JAMAIS réellement appelé par la boucle
/// d'orchestration — exactement comme côté web, où `researcher/index.ts`
/// intercepte le nom du dernier tool call AVANT tout appel à
/// `ActionRegistry.executeAll` et sort de la boucle sans jamais exécuter
/// l'action `done` elle-même (voir `SearchOrchestrator.runResearch`, qui fait
/// le même test sur `decision.actionName == "done"` avant tout `execute()`).
///
/// `execute()` reste donc du code mort ASSUMÉ, jamais couvert par un appel
/// réel dans le pipeline — commentaire volontairement explicite pour qu'un
/// futur lecteur ne le prenne pas pour un oubli : le comportement fidèle à
/// la référence web est justement de ne JAMAIS l'exécuter.
struct DoneAction: SearchAction {
    let name = "done"
    let descriptionForPlanner = "Signale que la recherche est terminée — arrête la boucle sans lancer de nouvelle action."

    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        .done
    }
}
