//
//  AIEngineOption+PrivacyBadge.swift
//  Triva
//

import Foundation

extension AIEngineOption {
    /// Icône, libellé et légende de confidentialité associés à ce moteur (voir DESIGN.md,
    /// section "Badge moteur IA"). Source unique de vérité : la mention "sur l'appareil" ne
    /// doit apparaître que pour les moteurs réellement locaux, jamais pour `.cloudBYOK`.
    var privacyBadge: (icon: String, text: String, caption: String) {
        switch self {
        case .appleIntelligence:
            ("lock.fill", "Apple Intelligence · Sur l'appareil", "Aucune donnée envoyée à un serveur")
        case .mlxLocal:
            ("lock.fill", "Modèle local (MLX) · Sur l'appareil", "Aucune donnée envoyée à un serveur")
        case .cloudBYOK:
            ("key.fill", "Clé API personnelle", "Envoyé directement à ton fournisseur — jamais à un serveur Triva")
        }
    }
}
