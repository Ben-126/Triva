//
//  OfflinePlan.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Pourquoi un envoi hors connexion ne peut pas aboutir (tâche 1.16). Chaque cas a son message, fixe :
/// aucune description d'erreur système ni texte renvoyé par un serveur n'y entre.
nonisolated enum OfflineBlockReason: Sendable, Equatable {
    /// Moteur « clé API personnelle » : la réponse vient d'un serveur du fournisseur. Aucune tentative.
    case cloudKey
    /// Moteur local : le modèle MLX choisi n'est pas (entièrement) sur l'appareil, ou n'a pas pu être
    /// chargé sans Internet. Le téléchargement a besoin du réseau.
    case localModelUnavailable
    /// Mode Fiable : il ne répond qu'avec des sources, et la recherche est impossible. Une réponse « de
    /// tête » trahirait la promesse du mode (décision (c) de Ben, 2026-10-30).
    case reliableMode
    /// La question porte sur la météo, qui n'a que le réseau pour source. Le widget n'est pas lancé et
    /// le modèle n'invente pas de météo.
    case weather

    /// Texte du bandeau. Tutoiement, phrases courtes, factuel (DESIGN.md).
    var message: String {
        switch self {
        case .cloudKey:
            "Hors connexion : ton fournisseur ne peut pas répondre sans Internet. Relance ta question au retour de la connexion."
        case .localModelUnavailable:
            "Hors connexion : le modèle local n'est pas disponible sur cet appareil sans Internet (téléchargement absent ou incomplet). Reconnecte-toi pour le télécharger, ou change de moteur dans les Réglages."
        case .reliableMode:
            "Hors connexion : le mode Fiable ne répond qu'avec des sources. Relance ta question au retour de la connexion, ou réponds sans source en mode Rapide."
        case .weather:
            "Hors connexion : la météo a besoin d'Internet. Relance ta question au retour de la connexion."
        }
    }

    /// Seul le mode Fiable a une issue immédiate : répondre hors connexion, sans source, en mode Rapide.
    /// Pour les deux autres, rien ne répondrait mieux en mode Rapide.
    var offersQuickModeAnswer: Bool { self == .reliableMode }
}

/// Ce que l'envoi doit faire QUAND l'appareil est hors connexion. `nil` côté appelant = connecté : le
/// pipeline normal. Calculé par `SearchSession` (qui connaît le moteur et les modèles sur disque), lu
/// par `ChatViewModel` à chaque envoi.
nonisolated enum OfflinePlan: Sendable, Equatable {
    /// Moteur sur l'appareil (Apple Intelligence, MLX avec modèle présent) : le modèle répond sans
    /// recherche web, avec la mention « Hors connexion, sans source ». Calcul et fichiers joints restent
    /// utilisables.
    case answerWithoutSearch
    /// Aucune tentative : message clair, bouton pour relancer au retour de la connexion.
    case blocked(OfflineBlockReason)

    /// - Parameters:
    ///   - engine: le moteur FIGÉ de la session.
    ///   - localModelAvailable: pour MLX, vrai si le modèle choisi est en mémoire ou entièrement sur le
    ///     disque. Vrai aussi quand AUCUN modèle n'est choisi : l'erreur d'origine (« Aucun modèle local
    ///     choisi », actionnable) est plus juste qu'un message sur le réseau.
    static func resolve(engine: AIEngineOption, localModelAvailable: Bool) -> OfflinePlan {
        switch engine {
        case .appleIntelligence:
            .answerWithoutSearch
        case .mlxLocal:
            localModelAvailable ? .answerWithoutSearch : .blocked(.localModelUnavailable)
        case .cloudBYOK:
            .blocked(.cloudKey)
        }
    }

    /// Ligne d'état permanente de l'écran de recherche tant que l'appareil est hors connexion.
    var statusText: String {
        switch self {
        case .answerWithoutSearch:
            "Hors connexion : le modèle répond sans recherche, donc sans source."
        case .blocked(let reason):
            reason == .cloudKey
                ? "Hors connexion : ton fournisseur a besoin d'Internet pour répondre."
                : "Hors connexion : le modèle local n'est pas disponible sans Internet."
        }
    }
}
