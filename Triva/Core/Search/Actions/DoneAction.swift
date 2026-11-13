//
//  DoneAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port fidèle de l'action `done` de la version web d'origine : registrée pour complétude (le nom
/// "done" est exposé au planner dans `SearchOrchestrator.plannerPrompt`),
/// mais son `execute()` n'est JAMAIS réellement appelé par la boucle
/// d'orchestration — exactement comme dans la version web d'origine, où la boucle de recherche
/// intercepte le nom du dernier tool call AVANT tout appel à
/// `ActionRegistry.executeAll` et sort de la boucle sans jamais exécuter
/// l'action `done` elle-même (voir `SearchOrchestrator.runPlannerLoop`, qui
/// sort de la boucle sur "done" — comme sur toute action inconnue — avant
/// tout `execute()`).
///
/// `execute()` reste donc du code mort ASSUMÉ, jamais couvert par un appel
/// réel dans le pipeline — commentaire volontairement explicite pour qu'un
/// futur lecteur ne le prenne pas pour un oubli : le comportement fidèle à
/// la version web d'origine est justement de ne JAMAIS l'exécuter.
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
