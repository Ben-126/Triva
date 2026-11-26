//
//  SearchSetupRequirement.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Ce qui manque au moteur de la session pour répondre — au premier lancement
/// comme après un réglage effacé ailleurs. Sert à ne jamais montrer un écran
/// vide ou un chat qui échouera à coup sûr sans dire pourquoi ni quoi faire.
enum SearchSetupRequirement: Equatable {
    /// Apple Intelligence choisi mais indisponible, pour la raison portée.
    case appleIntelligenceUnavailable(AppleIntelligenceError)
    /// MLX local choisi, aucun modèle validé.
    case mlxModel
    /// Clé API personnelle choisie, aucun fournisseur ni modèle sélectionné.
    case cloudProvider

    /// Explication affichée sous l'en-tête, ou `nil` quand le bouton d'action
    /// de l'en-tête (« Choisir un modèle MLX ») se suffit à lui-même.
    ///
    /// Jamais `String(describing:)` d'une erreur : l'écran affichait avant
    /// « Indisponible : deviceNotEligible », un identifiant anglais qui ne dit
    /// ni ce qui se passe ni quoi faire. Chaque message nomme l'issue — le
    /// bouton « Changer de moteur » est toujours juste au-dessus.
    var message: String? {
        switch self {
        case .appleIntelligenceUnavailable(let error):
            return Self.message(for: error)
        case .mlxModel:
            return nil
        case .cloudProvider:
            return "Ajoute ta clé API, puis choisis un fournisseur et un modèle dans les Réglages."
        }
    }

    private static func message(for error: AppleIntelligenceError) -> String {
        switch error {
        case .deviceNotEligible:
            "Cet appareil ne prend pas en charge Apple Intelligence. Choisis un autre moteur."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence est désactivé. Active-le dans les réglages de l'appareil, ou choisis un autre moteur."
        case .modelNotReady:
            "Le modèle Apple Intelligence est en cours de téléchargement. Réessaie dans quelques minutes."
        case .unavailableForOtherReason:
            "Apple Intelligence n'est pas disponible pour le moment. Réessaie plus tard, ou choisis un autre moteur."
        case .generationFailed:
            // Jamais produit par la vérification de disponibilité ; le texte
            // porté vient du framework, il n'est pas repris.
            "Apple Intelligence n'a pas pu répondre. Réessaie."
        }
    }
}
