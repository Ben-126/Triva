//
//  SearchOrchestrator+Offline.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Mode hors connexion de l'orchestrateur (tâche 1.16). Sorti du fichier principal, déjà très au-delà
/// des 800 lignes.
///
/// CE QUI CHANGE quand `SearchOrchestrator.isOffline` est vrai :
/// - AUCUNE recherche web (ni SearXNG, ni la chaîne de repli, ni les sources ouvertes) : la route
///   `.web` / `.webUnlessWeatherAnswered` devient `.none`. Les FICHIERS JOINTS restent consultés : ils
///   sont sur l'appareil, leurs extraits sont de vraies sources citables.
/// - le widget météo n'est pas lancé : il n'aurait que réseau à offrir. La question de météo est
///   signalée (`SearchArtifacts.offlineWeatherSkipped`) et `ChatViewModel` répond par un message fixe.
/// - la calculatrice reste disponible : elle tourne sur l'appareil (`CalculationWidget`).
/// - la réponse, rédigée par le modèle local sans source, est marquée (`SearchArtifacts.answeredOffline`).
///
/// CE QUI NE CHANGE PAS : la classification (un appel au modèle local), le prompt et la validation.
/// Hors connexion avec un moteur cloud, l'orchestrateur n'est jamais construit (`OfflinePlan.blocked`).
extension SearchOrchestrator {
    /// Les routes qui font du réseau deviennent « aucune recherche ». Les fichiers joints gardent la
    /// main : `routeConsultingAttachments` les rétablit au besoin.
    nonisolated static func routeAvailable(_ route: SearchRoute, isOffline: Bool, hasAttachments: Bool) -> SearchRoute {
        guard isOffline else { return route }
        switch route {
        case .web, .webUnlessWeatherAnswered:
            return routeConsultingAttachments(.none, hasAttachments: hasAttachments)
        case .none, .attachments:
            return route
        }
    }

    /// Hors connexion, la météo (réseau seul) disparaît de la liste ; le calcul reste.
    nonisolated static func widgetsAvailable(_ widgets: [any SearchWidget], isOffline: Bool) -> [any SearchWidget] {
        isOffline ? widgets.filter { $0.kind != .weather } : widgets
    }
}
