//
//  WidgetSnapshotPublisher.swift
//  Triva
//
//  Chantier 2.1 (mission C) : l'app écrit, le widget lit. À chaque changement d'historique (et au lancement, et
//  quand le réglage bascule), on calcule l'instantané voulu, on le compare à celui du disque, et on ne réécrit
//  et ne recharge le widget que s'il diffère.
//
//  Réglage « Dernière question dans le widget » ÉTEINT (défaut) : on n'écrit RIEN, et l'instantané déjà présent
//  est effacé. Les téléphones, comme les Mac, ne gardent alors dans l'App Group aucune question.
//

import Foundation
import OSLog
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    /// Ce qui s'est passé lors d'une publication ; sert aux tests et aux journaux.
    enum Outcome: Equatable {
        /// Déjà à jour (ou rien à faire) : ni écriture ni rechargement.
        case unchanged
        case written
        case removed
        /// L'App Group n'est pas disponible (app non signée avec le groupe) : le widget n'est pas alimenté.
        case unavailable
        case failed(String)
    }

    /// Ce que l'app sait de la dernière conversation, avant nettoyage du titre.
    struct LatestConversation: Equatable {
        let id: UUID
        let title: String
        let updatedAt: Date
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "WidgetSnapshot"
    )

    private let store: WidgetSnapshotStore?
    private let preferences: SystemIntegrationPreferences
    private let reload: @MainActor () -> Void

    init(store: WidgetSnapshotStore?, preferences: SystemIntegrationPreferences, reload: @escaping @MainActor () -> Void) {
        self.store = store
        self.preferences = preferences
        self.reload = reload
    }

    /// Le publieur de l'app : App Group réel, réglages de l'app, rechargement du widget « Recherche rapide ».
    static func live() -> WidgetSnapshotPublisher {
        WidgetSnapshotPublisher(
            store: AppGroupFileStore.live().map { WidgetSnapshotStore(files: $0) },
            preferences: SystemIntegrationPreferences(),
            reload: { WidgetCenter.shared.reloadTimelines(ofKind: TrivaWidgetKind.quickSearch) }
        )
    }

    /// Aligne l'instantané du disque sur l'historique et le réglage.
    @discardableResult
    func publish(latest: LatestConversation?) -> Outcome {
        guard let store else { return .unavailable }
        guard preferences.showsLastQuestionInWidget else { return removeSnapshot(from: store) }

        let desired = latest.map { WidgetSnapshot(conversationID: $0.id, title: $0.title, updatedAt: $0.updatedAt) } ?? .empty
        guard store.load() != desired else { return .unchanged }
        do {
            try store.save(desired)
        } catch {
            return failure("écriture de l'instantané", error)
        }
        reload()
        return .written
    }

    /// « Tout effacer » : retire l'instantané, quel que soit le réglage.
    @discardableResult
    func erase() -> Outcome {
        guard let store else { return .unavailable }
        return removeSnapshot(from: store)
    }

    private func removeSnapshot(from store: WidgetSnapshotStore) -> Outcome {
        guard store.exists else { return .unchanged }
        do {
            try store.delete()
        } catch {
            return failure("suppression de l'instantané", error)
        }
        reload()
        return .removed
    }

    /// Le journal ne reçoit que la nature de l'erreur : jamais un titre de conversation.
    private func failure(_ action: String, _ error: Error) -> Outcome {
        let reason = String(describing: error)
        Self.logger.error("Widget : \(action, privacy: .public) a échoué : \(reason, privacy: .private)")
        return .failed(reason)
    }
}
