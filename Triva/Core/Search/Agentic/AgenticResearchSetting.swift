//
//  AgenticResearchSetting.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation

/// Drapeau de la recherche menée par l'IA (tâche 2.4). ÉTEINT par défaut, et toujours éteint hors DEBUG,
/// jusqu'à la comparaison (M4) et la décision de Ben (M5). En DEBUG, argument de lancement
/// `-research.agentic YES` (domaine volatil de `UserDefaults`, rien n'est persisté), sur le modèle de
/// `-debug.simulatePrivateCloud`. Aucun réglage visible : aucun texte nouveau.
nonisolated enum AgenticResearchSetting {
    static let defaultsKey = "research.agentic"

    static var isEnabled: Bool { isEnabled(in: .standard) }

    /// `defaults` injectable pour les tests.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        #if DEBUG
        defaults.bool(forKey: defaultsKey)
        #else
        false
        #endif
    }
}
