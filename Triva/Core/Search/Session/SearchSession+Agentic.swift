//
//  SearchSession+Agentic.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation

/// Enquêteur de la recherche web d'un envoi (tâche 2.4, spec §2.5) : construit SEULEMENT pour Apple
/// Intelligence et drapeau allumé. MLX et les clés cloud reçoivent `nil` : leur pipeline est intouché.
extension SearchSession {
    /// Appelé par `ChatViewModel` juste après `resolveProviderForSending()`, sans suspension : la route du
    /// modèle (`appleModel.lastSendingRoute`) est celle de CE même envoi.
    func agenticResearcherForSending(isEnabled: Bool = AgenticResearchSetting.isEnabled) -> (any AgenticResearching)? {
        guard Self.usesAgenticResearch(engine: engine, isEnabled: isEnabled) else { return nil }
        let coordinator = appleModel
        return AgenticResearcherFactory.researcher(
            route: coordinator.lastSendingRoute,
            onPrivateCloudFailure: { [weak coordinator] failure in coordinator?.recordFailure(failure) }
        )
    }

    /// Règle pure : Apple Intelligence et drapeau allumé, rien d'autre.
    static func usesAgenticResearch(engine: AIEngineOption, isEnabled: Bool) -> Bool {
        isEnabled && engine == .appleIntelligence
    }
}
