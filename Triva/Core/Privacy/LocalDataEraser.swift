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

    var failedSteps: [LocalDataEraseStep] {
        switch self {
        case .incomplete(let steps): steps
        }
    }
}

/// Ce que « Tout effacer » sait vider en base. `ChatHistoryStore` et
/// `FavoritesStore` s'y conforment ; le protocole existe pour que les tests
/// fassent échouer UNE étape sans toucher à l'autre (un échec partiel est la
/// promesse la plus délicate de `LocalDataEraser`).
@MainActor
protocol AllDeleting {
    func deleteAll() throws
}

extension ChatHistoryStore: AllDeleting {}
extension FavoritesStore: AllDeleting {}

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
/// Base locale inaccessible (`TrivaStorage` indisponible) : les deux étapes
/// échouent (`storageUnavailable`), l'effacement est déclaré `incomplete` et
/// l'écran le dit — jamais « Tout a été effacé » alors que le fichier sur
/// disque, qu'on ne sait pas ouvrir, est intact. Ce fichier n'est volontairement
/// pas supprimé d'autorité (question ouverte E1a).
///
/// Le chat ouvert n'a rien à faire : `ChatHistoryStore.deleteAll()` incrémente
/// `revision`, et `TrivaRootCoordinator.historyDidChange()` vide le fil dont la
/// conversation a disparu (voir son commentaire, qui prévoit déjà ce cas).
@MainActor
struct LocalDataEraser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "LocalDataEraser"
    )

    private let chatHistory: any AllDeleting
    private let favorites: any AllDeleting
    private let discoverCache: any DiscoverContentCaching
    private let urlCache: URLCache

    init(
        chatHistory: any AllDeleting,
        favorites: any AllDeleting,
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
