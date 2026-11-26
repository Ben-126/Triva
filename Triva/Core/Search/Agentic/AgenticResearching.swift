//
//  AgenticResearching.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation

/// Enquêteur de la recherche web (tâche 2.4, spec §2.5) : à partir des résultats de départ, l'IA cherche et
/// lit elle-même avec des outils, puis rend son registre. Il ne rédige JAMAIS la réponse : le rédacteur actuel
/// (`buildPrompt` puis `aiProvider.streamGenerate`) reste seul à écrire (décision de Ben du 2026-11-24).
///
/// Implémentation réelle : `AppleAgenticResearcher` (Apple Intelligence seulement). Les tests de
/// l'orchestrateur passent des doubles. `nil` dans l'orchestrateur = comportement d'avant la tâche 2.4.
nonisolated protocol AgenticResearching: Sendable {
    /// Lève `AgenticResearchFailure` pour tout échec (l'orchestrateur reprend alors la boucle actuelle sur
    /// les résultats de départ), et l'annulation telle quelle (`CancellationError`, aucun repli).
    func investigate(_ request: AgenticResearchRequest) async throws -> AgenticResearchOutcome
}

/// Ce que seul l'orchestrateur connaît au moment d'enquêter. `search` et `scrape` sont bâtis par
/// `SearchOrchestrator+Agentic` sur SES `failoverManager`, `webSearchChain` et `scrapeService` : l'enquêteur
/// cherche avec la MÊME chaîne que le départ et lit avec le même service (robots.txt et `noai` respectés).
nonisolated struct AgenticResearchRequest: Sendable {
    /// Question telle que l'utilisateur l'a posée.
    let question: String
    /// Sujet de recherche effectif (reformulation du classifieur, `SearchOrchestrator.effectiveQuery`).
    let searchQuery: String
    /// Résultats bruts du départ, dans l'ordre du moteur.
    let seeded: [SearXNGSearchResult]
    let budget: ResearchBudget
    /// Mode Fiable : seuls les domaines fiables reçoivent un numéro (donc peuvent être montrés ou lus).
    let trustedDomainsOnly: Bool
    let search: WebSearchTool.Search
    let scrape: ReadPageTool.Scrape
    /// Date du jour donnée au modèle (questions d'actualité).
    let today: Date
}

/// Pourquoi l'enquête s'est arrêtée sans erreur.
nonisolated enum AgenticStop: Sendable, Equatable {
    /// `finish` appelé, ou le modèle a rendu un texte sans appeler d'outil de plus.
    case finished
    /// Un plafond du registre a refusé un appel : on garde ce qui a été trouvé.
    case budgetReached
    /// Délai du mode écoulé : on garde ce qui a été trouvé.
    case timedOut
}

/// Résultat d'une enquête menée à son terme (même partiel). Tout se lit dans le registre : à la sentinelle,
/// le transcript du modèle est restauré (prototype A1), jamais relu.
nonisolated struct AgenticResearchOutcome: Sendable, Equatable {
    let snapshot: ResearchLedger.Snapshot
    let stop: AgenticStop
}

/// Raison d'un repli sur la boucle actuelle. Diagnostic seulement : jamais affiché, jamais persisté.
nonisolated enum AgenticFallbackReason: Sendable, Equatable {
    /// L'enquête n'a rien rapporté de plus que le départ.
    case noFindings
    /// Délai écoulé sans rien trouver.
    case timedOut
    /// `LanguageModelError.contextSizeExceeded`.
    case contextExceeded
    /// `LanguageModelError.guardrailViolation`.
    case guardrail
    /// `LanguageModelError.refusal`.
    case refusal
    /// `LanguageModelError.rateLimited` (modèle sur l'appareil).
    case rateLimited
    /// `LanguageModelError.timeout` (délai propre au modèle).
    case modelTimeout
    /// Capacité, langue, guide ou contenu non pris en charge par le modèle.
    case unsupported
    /// Ressources du modèle indisponibles (`SystemLanguageModel.Error`).
    case modelUnavailable
    /// Échec du cloud privé pendant l'enquête (classé par `PrivateCloudFailure.classify`).
    case privateCloud(PrivateCloudFailure)
    /// Un outil a levé une erreur inattendue.
    case toolFailed
    /// Toute autre erreur.
    case other
}

/// Échec de l'enquêteur : l'orchestrateur reprend la boucle actuelle sur les résultats de départ.
nonisolated struct AgenticResearchFailure: Error, Equatable {
    let reason: AgenticFallbackReason
}

/// Chemin suivi par la recherche web d'un envoi (`SearchArtifacts.researchPath`). Diagnostic pour le journal
/// et le banc de comparaison (M4) : jamais affiché, jamais persisté.
nonisolated enum ResearchPath: Sendable, Equatable {
    /// Boucle actuelle (pas d'enquêteur, mode Rapide, ou pas de recherche web).
    case classic
    /// Sources choisies par l'enquêteur.
    case agentic
    /// Enquêteur tenté puis abandonné : boucle actuelle sur les résultats de départ.
    case agenticFellBack(AgenticFallbackReason)
}
