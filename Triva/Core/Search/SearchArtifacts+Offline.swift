//
//  SearchArtifacts+Offline.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Ce que le mode hors connexion (tâche 1.16) ajoute aux artefacts d'une réponse.
extension SearchArtifacts {
    /// Mention « Hors connexion, sans source » : même règle que « Réponse sans recherche »
    /// (`answersWithoutSearch` : ni recherche, ni widget, ni salutation) appliquée à un appareil hors
    /// connexion. Elle REMPLACE l'autre mention, plus vague (voir `MessageBubblePresentation`).
    nonisolated func markedOffline(_ isOffline: Bool, weatherSkipped: Bool) -> SearchArtifacts {
        guard isOffline else { return self }
        var marked = self
        marked.answeredOffline = answeredWithoutSearch
        marked.offlineWeatherSkipped = weatherSkipped
        return marked
    }

    /// Mode Fiable hors connexion : la réponse serait rédigée sans aucune source, ce que le mode
    /// promet de ne jamais faire (décision (c) de Ben, voir `lacksReliableSources`). Un widget (calcul)
    /// ou une salutation y échappent, comme en ligne : `answeredOffline` les exclut déjà.
    nonisolated var blocksReliableOffline: Bool {
        guard answeredOffline, case .reliable = mode else { return false }
        return true
    }

    /// Rien à générer : réponse fixe côté appelant (météo hors connexion) ou état bloqué (Fiable).
    /// Critère partagé par `SearchOrchestrator.streamAnswer` et `ChatViewModel`.
    nonisolated var withholdsAnswerOffline: Bool {
        offlineWeatherSkipped || blocksReliableOffline
    }

    /// Pourquoi l'appelant ne doit rien générer (`nil` = on génère). La météo prime : c'est la demande
    /// de l'utilisateur, le mode Fiable n'en est que le cadre.
    nonisolated var offlineBlockReason: OfflineBlockReason? {
        if offlineWeatherSkipped { return .weather }
        return blocksReliableOffline ? .reliableMode : nil
    }
}
