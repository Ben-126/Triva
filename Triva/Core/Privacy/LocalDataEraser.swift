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
    /// Le navigateur intégré (iPhone, iPad) n'a pas pu être vidé : Safari n'a pas répondu dans le délai.
    case browser
    /// Ce que l'app avait publié hors d'elle (widget, boîte de partage, recherche de l'appareil, activités en direct)
    /// n'a pas pu être entièrement retiré (chantier 2.1).
    case systemIntegrations
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

/// Ce que « Tout effacer » demande aux intégrations système (widget, partage, Spotlight, activités en direct) :
/// `true` si TOUT a été retiré. `SystemIntegrations` s'y conforme ; les tests passent un faux (jamais le vrai App Group).
@MainActor
protocol SystemIntegrationsErasing {
    func eraseAll() async -> Bool
}

extension ChatHistoryStore: AllDeleting {}
extension FavoritesStore: AllDeleting {}

/// Action « Tout effacer » des Réglages : conversations, favoris et caches
/// locaux. Le détail de ce qui est effacé — et de ce qui NE l'est PAS — est
/// la promesse faite à l'utilisateur, il est donc figé ici :
///
/// - EFFACÉ : favoris, historique (conversations, messages, sources), cache
///   HTTP partagé (`URLCache.shared`), cache de l'écran Découvrir, pages lues à la
///   demande, refus des sites et règles robots.txt gardés en mémoire, et — sur iPhone et iPad —
///   cookies, stockage local et cache du navigateur intégré (`SFSafariViewController.DataStore`).
///   Sur Mac, la fenêtre du navigateur intégré utilise un stockage non persistant : rien à effacer.
///   Ce que l'app a publié hors d'elle (chantier 2.1) : instantané du widget, boîte de partage de l'extension
///   (fichiers compris), titres et dates dans la recherche de l'appareil (Spotlight), activités en direct —
///   quand l'app lui donne `systemIntegrations` (les tests passent un faux, jamais le vrai App Group du Mac).
///   Copies temporaires de pièces jointes (dossier `tmp/TrivaAttachments`, Coup d'œil et glisser-déposer),
///   quand l'app lui donne leur dossier (`attachmentVaultRoot`) : y compris celles des fenêtres ouvertes, dont
///   l'aperçu est fermé avant (`AttachmentVaultPurgeSignal`) ; leur Coup d'œil n'est plus proposé ensuite.
/// - JAMAIS TOUCHÉ : clés API (Trousseau), choix du moteur IA, fournisseur et
///   modèle choisis, instances SearXNG, modèles MLX téléchargés. Cet objet ne
///   reçoit d'ailleurs ni le trousseau ni aucun store de réglages : il ne peut
///   pas les effacer par mégarde.
///
/// Safari (navigateur intégré, iPhone et iPad) qui ne répond pas en 10 s : l'effacement continue sans l'attendre,
/// puis est déclaré `.incomplete` avec l'étape `.browser` — jamais « Tout a été effacé » (décision de Ben, 2026-11-24).
///
/// ## Chemin principal : `deleteAllData()` (décision de Ben, 2026-11-14)
/// Quand le stockage sait se rouvrir (`TrivaStorage.eraseAllData()`, base sur
/// disque), toute la base est effacée d'un coup par `ModelContainer.deleteAllData()`
/// — rien ne reste dans `.store`, `-wal` ni `-shm` — puis un conteneur neuf est
/// recréé et tous les consommateurs passent dessus. Une génération en cours est
/// arrêtée AVANT (`beforeErase`), pour qu'elle n'écrive pas dans la base
/// pendant ou après l'effacement.
///
/// ## Repli : suppression objet par objet
/// Si `deleteAllData()` échoue, ou si le stockage ne sait pas se rouvrir
/// (conteneur injecté : tests, aperçus), chaque store efface ses objets et
/// l'échec éventuel d'une étape est dit tel quel (`.incomplete`). Les favoris
/// partent AVANT l'historique : un favori pointe vers une conversation, on ne
/// laisse pas de lien orphelin si la seconde étape échoue.
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
    private let storage: TrivaStorage?
    private let beforeErase: (@MainActor () async -> Void)?
    private let clearBrowserData: @MainActor () async -> EmbeddedBrowserClearOutcome
    private let attachmentVaultRoot: URL?
    private let previewDismissDelay: Duration
    private let vaultPurgeCenter: NotificationCenter
    private let systemIntegrations: (any SystemIntegrationsErasing)?

    /// - Parameters:
    ///   - storage: stockage à effacer d'un coup (`deleteAllData()` puis
    ///     conteneur neuf). `nil` : suppression objet par objet seulement.
    ///   - beforeErase: appelée avant tout effacement ; l'app y arrête la
    ///     génération en cours et attend sa fin.
    ///   - attachmentVaultRoot: dossier des copies temporaires de pièces jointes
    ///     (Coup d'œil, glisser-déposer), vidé en entier. `nil` : rien n'est
    ///     touché (tests : ne jamais effacer le vrai coffre de la machine).
    init(
        chatHistory: any AllDeleting,
        favorites: any AllDeleting,
        discoverCache: any DiscoverContentCaching,
        urlCache: URLCache = .shared,
        storage: TrivaStorage? = nil,
        beforeErase: (@MainActor () async -> Void)? = nil,
        clearBrowserData: @escaping @MainActor () async -> EmbeddedBrowserClearOutcome = LocalDataEraser.clearEmbeddedBrowserData,
        attachmentVaultRoot: URL? = nil,
        previewDismissDelay: Duration = .milliseconds(250),
        vaultPurgeCenter: NotificationCenter = .default,
        systemIntegrations: (any SystemIntegrationsErasing)? = nil
    ) {
        self.chatHistory = chatHistory
        self.favorites = favorites
        self.discoverCache = discoverCache
        self.urlCache = urlCache
        self.storage = storage
        self.beforeErase = beforeErase
        self.clearBrowserData = clearBrowserData
        self.attachmentVaultRoot = attachmentVaultRoot
        self.previewDismissDelay = previewDismissDelay
        self.vaultPurgeCenter = vaultPurgeCenter
        self.systemIntegrations = systemIntegrations
    }

    /// Joue toutes les étapes puis lève `LocalDataEraseError.incomplete` si une
    /// suppression en base a échoué (jamais d'erreur avalée).
    func eraseAll() async throws(LocalDataEraseError) {
        await beforeErase?()
        await announceVaultPurge()
        var failed = eraseDatabase()
        await Self.clearCaches(urlCache: urlCache, discoverCache: discoverCache)
        // Ce que l'app avait publié hors d'elle à partir de l'historique (chantier 2.1) : instantané du widget, boîte
        // de partage, index Spotlight, activités en direct. Après la base : tout en vient.
        if let systemIntegrations, await systemIntegrations.eraseAll() == false {
            failed.append(.systemIntegrations)
        }
        // Pages lues à la demande (« Lire cette page »), refus des sites et
        // règles robots.txt en mémoire : elles révèlent les sites consultés.
        UserReadPages.removeAll()
        SiteReadRefusals.shared.removeAll()
        await RobotsRulesCache.shared.removeAll()
        // Safari muet : l'effacement continue (le reste est vidé), mais l'utilisateur est prévenu.
        if await clearBrowserData() == .timedOut {
            failed.append(.browser)
        }
        // Copies temporaires de documents joints (chantier 2.2) : ce sont des données de l'utilisateur aussi.
        if let attachmentVaultRoot {
            AttachmentFileVault.purgeAll(rootDirectory: attachmentVaultRoot)
        }

        if !failed.isEmpty {
            throw .incomplete(failedSteps: failed)
        }
    }

    /// Prévient les fenêtres ouvertes que leurs copies de fichiers vont disparaître : leur aperçu (Coup d'œil) se
    /// ferme et elles les oublient. Le délai laisse l'interface réellement fermer un aperçu avant que son fichier
    /// ne soit supprimé (la suppression a lieu en fin d'effacement). Sans dossier de coffre, rien n'est supprimé,
    /// donc rien n'est annoncé.
    private func announceVaultPurge() async {
        guard let attachmentVaultRoot else { return }
        AttachmentVaultPurgeSignal.post(root: attachmentVaultRoot, on: vaultPurgeCenter)
        try? await Task.sleep(for: previewDismissDelay)
    }

    /// Efface la base : d'un coup si le stockage le permet, sinon (ou si cela
    /// échoue) objet par objet. Renvoie les étapes restées en échec.
    private func eraseDatabase() -> [LocalDataEraseStep] {
        if let storage {
            do {
                try storage.eraseAllData()
                return []
            } catch .reopeningNotSupported {
                // Conteneur injecté : repli normal, rien à journaliser.
            } catch {
                Self.logger.error("Effacement complet impossible, repli objet par objet : \(String(describing: error), privacy: .private)")
            }
        }
        return eraseObjectByObject()
    }

    private func eraseObjectByObject() -> [LocalDataEraseStep] {
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
        return failed
    }

    /// Vide cookies, stockage local et cache du navigateur intégré. iPhone et iPad seulement : le Mac
    /// ouvre ses liens dans une fenêtre `WebView` à stockage non persistant (`InAppBrowser.swift`).
    ///
    /// Un seul vidage à la fois, avec un délai maximal : voir `EmbeddedBrowserDataClearer` (des appels
    /// simultanés s'invalident entre eux et ne rendent jamais la main).
    static func clearEmbeddedBrowserData() async -> EmbeddedBrowserClearOutcome {
        await EmbeddedBrowserDataClearer.shared.clear()
    }

    /// Hors main actor : vider une base SQLite de cache peut être long.
    @concurrent
    private static func clearCaches(urlCache: URLCache, discoverCache: any DiscoverContentCaching) async {
        urlCache.removeAllCachedResponses()
        await discoverCache.clear()
    }
}
