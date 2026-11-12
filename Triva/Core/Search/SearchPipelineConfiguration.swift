//
//  SearchPipelineConfiguration.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Budgets du pipeline selon le moteur IA ACTIF (bug 6 de la revue). Avant,
/// tous les moteurs recevaient ceux d'un modèle cloud (128k tokens et plus) :
/// classifieur `.full` (~6 400 caractères), historique de longueur illimitée
/// côté classifieur, 8 000 caractères de pages scrapées. Apple Intelligence
/// (~4 096 tokens, prompt ET réponse) débordait dès la classification — échec
/// avalé par `bestEffort`, donc classification « tout à false » à chaque tour
/// (plus de `.skip`, plus de routage) — puis au prompt final.
///
/// Une seule complexité pour les DEUX prompts (classification, rédaction) :
/// ce qui noie un petit modèle, c'est la longueur des consignes, la même dans
/// les deux étapes. `maxResultsUsedForContext` reste un PLAFOND du mode (voir
/// l'init de `SearchOrchestrator`). Budgets en caractères, proxy des tokens
/// (~4 caractères par token en français, ~1 en chinois ou japonais) : ils ne
/// protègent pas entièrement un texte CJK, d'où des marges larges — le
/// débordement résiduel doit devenir un message clair côté `ChatViewModel`.
nonisolated struct SearchPipelineConfiguration: Sendable, Equatable {
    let promptComplexity: WriterPromptComplexity
    let maxHistoryMessages: Int
    let maxHistoryMessageCharacters: Int
    let maxScrapedContextCharacters: Int
    let maxResultsUsedForContext: Int
    let maxScrapedURLsPerIteration: Int

    /// Cloud BYOK : les valeurs historiques du pipeline, inchangées (défauts
    /// de `PromptTemplates`, 5 sources, 3 pages par tour).
    static let cloud = SearchPipelineConfiguration(
        promptComplexity: .full,
        maxHistoryMessages: PromptTemplates.defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: PromptTemplates.defaultMaxHistoryMessageCharacters,
        maxScrapedContextCharacters: PromptTemplates.defaultMaxScrapedContextCharacters,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// Apple Intelligence : prompts courts, 4 messages × 600 caractères,
    /// 3 000 caractères scrapés partagés entre 2 pages par tour (1 500 chacune
    /// plutôt que 1 000 sur 3). Les 5 extraits SearXNG restent : c'est le
    /// contexte le plus dense par caractère. Pire cas mesuré par
    /// `PromptTemplatesTests` : sous 10 000 caractères (~2 500 tokens en
    /// français), ce qui laisse ~1 500 tokens à la réponse. Même borne tenue
    /// avec des fichiers joints trouvés par le planner et deux widgets
    /// (`UploadsSearchPipelineTests`) : les fichiers partagent le budget des
    /// pages (`SearchOrchestrator.scrapedContextBudget`) et 5 extraits au plus
    /// y entrent (`SearchOrchestrator.attachmentFragmentLimit(forBudget:)`).
    static let appleIntelligence = SearchPipelineConfiguration(
        promptComplexity: .concise,
        maxHistoryMessages: 4,
        maxHistoryMessageCharacters: 600,
        maxScrapedContextCharacters: 3000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 2
    )

    /// MLX léger (Qwen3 0.6B, 1.7B) : fenêtre de 32k tokens, mais un modèle de
    /// cette taille se perd dans de longues consignes (raison d'être de
    /// `.concise`), et chaque token de prompt coûte du pré-remplissage et du
    /// cache KV en mémoire sur l'appareil.
    static let mlxCompact = SearchPipelineConfiguration(
        promptComplexity: .concise,
        maxHistoryMessages: 6,
        maxHistoryMessageCharacters: 1000,
        maxScrapedContextCharacters: 5000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// MLX 4B et plus : consignes complètes, budgets proches du cloud, un peu
    /// réduits pour la même raison de latence et de mémoire sur l'appareil.
    /// Valeurs de départ, à ajuster sur iPhone réel.
    static let mlx = SearchPipelineConfiguration(
        promptComplexity: .full,
        maxHistoryMessages: 6,
        maxHistoryMessageCharacters: 1500,
        maxScrapedContextCharacters: 6000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// `capabilityScore` (catalogue MLX) des Qwen3 0.6B (1) et 1.7B (2) : les
    /// modèles visés par `WriterPromptComplexity.concise`.
    static let maxCompactMLXCapabilityScore = 2

    /// Préréglage du moteur RÉELLEMENT résolu pour la requête, comme le
    /// provider lui-même (`ActiveAIProviderResolver`) : un budget lu ailleurs
    /// pourrait décrire un autre moteur que celui qui répond. `mlxModel` :
    /// l'entrée du catalogue sélectionnée ; inconnue, on suppose le plus petit
    /// modèle — un budget trop serré dégrade une réponse, un budget trop large
    /// la perd. `@MainActor` : `AIEngineOption` et `MLXModelCatalogEntry` sont
    /// des types non annotés, isolés au main actor (appelant : `ChatViewModel`).
    @MainActor
    static func preset(for engine: AIEngineOption, mlxModel: MLXModelCatalogEntry? = nil) -> SearchPipelineConfiguration {
        switch engine {
        case .appleIntelligence:
            return .appleIntelligence
        case .cloudBYOK:
            return .cloud
        case .mlxLocal:
            guard let mlxModel, mlxModel.capabilityScore > maxCompactMLXCapabilityScore else { return .mlxCompact }
            return .mlx
        }
    }

    /// Même choix pour le classifieur, dont l'enum est isolé au main actor
    /// (type non annoté de `QueryClassifier.swift`).
    @MainActor
    var classifierPromptComplexity: ClassifierPromptComplexity {
        switch promptComplexity {
        case .full: .full
        case .concise: .concise
        }
    }
}
