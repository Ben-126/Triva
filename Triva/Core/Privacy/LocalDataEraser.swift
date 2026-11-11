//
//  LocalDataEraser.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation
import OSLog

/// Étapes de « Tout effacer », dans l'ordre où elles s'exécutent.
nonisolated enum LocalDataEraseStep: String, Sendable, Equatable, CaseIterable {
    case favorites
    case history
}

/// Échec d'au moins une étape de suppression en base. Les autres étapes ont
/// quand même été jouées : un historique illisible ne doit pas laisser le cache
/// HTTP (les questions en clair) sur le disque.
nonisolated enum LocalDataEraseError: Error, Sendable, Equatable {
    case incomplete(failedSteps: [LocalDataEraseStep])
}

/// Action « Tout effacer » des Réglages : conversations, favoris et caches
/// locaux. Le détail de ce qui est effacé — et de ce qui NE l'est PAS — est
/// la promesse faite à l'utilisateur, il est donc figé ici :
///
/// - EFFACÉ : favoris, historique (conversations, messages, sources), cache
///   HTTP partagé (`URLCache.shared`), cache de l'écran Découvrir.
/// - JAMAIS TOUCHÉ : clés API (Trousseau), choix du moteur IA, fournisseur et
///   modèle choisis, instances SearXNG, modèles MLX téléchargés. Cet objet ne
///   reçoit d'ailleurs ni le trousseau ni aucun store de réglages : il ne peut
///   pas les effacer par mégarde.
///
/// Les favoris partent AVANT l'historique : un favori pointe vers une
/// conversation, on ne laisse pas de lien orphelin si la seconde étape échoue.
/// Le chat ouvert n'a rien à faire : `ChatHistoryStore.deleteAll()` incrémente
/// `revision`, et `TrivaRootCoordinator.historyDidChange()` vide le fil dont la
/// conversation a disparu (voir son commentaire, qui prévoit déjà ce cas).
@MainActor
struct LocalDataEraser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "LocalDataEraser"
    )

    private let chatHistory: ChatHistoryStore
    private let favorites: FavoritesStore
    private let discoverCache: any DiscoverContentCaching
    private let urlCache: URLCache

    init(
        chatHistory: ChatHistoryStore,
        favorites: FavoritesStore,
        discoverCache: any DiscoverContentCaching,
        urlCache: URLCache = .shared
    ) {
        self.chatHistory = chatHistory
        self.favorites = favorites
        self.discoverCache = discoverCache
        self.urlCache = urlCache
    }

    /// Joue toutes les étapes puis lève `LocalDataEraseError.incomplete` si une
    /// suppression en base a échoué (jamais d'erreur avalée).
    func eraseAll() async throws(LocalDataEraseError) {
        var failed: [LocalDataEraseStep] = []

        do {
            try favorites.deleteAll()
        } catch {
            Self.logger.error("Favoris non effacés : \(String(describing: error), privacy: .private)")
            failed.append(.favorites)
        }
        do {
            try chatHistory.deleteAll()
        } catch {
            Self.logger.error("Historique non effacé : \(String(describing: error), privacy: .private)")
            failed.append(.history)
        }

        await Self.clearCaches(urlCache: urlCache, discoverCache: discoverCache)

        if !failed.isEmpty {
            throw .incomplete(failedSteps: failed)
        }
    }

    /// Hors main actor : vider une base SQLite de cache peut être long.
    @concurrent
    private static func clearCaches(urlCache: URLCache, discoverCache: any DiscoverContentCaching) async {
        urlCache.removeAllCachedResponses()
        await discoverCache.clear()
    }
}
