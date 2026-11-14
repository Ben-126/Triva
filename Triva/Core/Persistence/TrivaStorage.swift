//
//  TrivaStorage.swift
//  Triva
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import OSLog
import SwiftData

/// Propriétaire du stockage local de l'app : ouvre la base SwiftData et dit
/// honnêtement si elle est disponible (décision de Ben, K8).
///
/// ## Pourquoi cet objet existe
/// Avant, une base illisible (fichier corrompu, schéma incompatible, disque
/// verrouillé) faisait basculer l'app EN SILENCE sur un conteneur en mémoire :
/// la Bibliothèque paraissait vide et tout ce qui était écrit ensuite
/// disparaissait. Maintenant :
/// 1. l'ouverture est retentée plusieurs fois, vite (`retryDelaysMilliseconds`),
///    sans que l'utilisateur ne voie rien si l'une des tentatives réussit ;
/// 2. si elle échoue toujours, `state` vaut `.unavailable` : les stores
///    (`ChatHistoryStore`, `FavoritesStore`) REFUSENT de lire et d'écrire
///    (`storageUnavailable`) plutôt que d'écrire dans le vide, la Bibliothèque
///    et les Favoris affichent un écran d'erreur avec « Réessayer »
///    (`retry()`), et le chat signale que l'échange n'est pas enregistré ;
/// 3. aucune opération ici ne modifie, ne déplace ni n'efface le fichier sur
///    disque : on ne fait qu'essayer de l'ouvrir. L'ancienne base est
///    intacte, et une version ou un essai ultérieur la retrouvera.
///
/// Un seul objet est partagé par `ChatHistoryStore` et `FavoritesStore` : un
/// « Réessayer » réussi les rebranche tous les deux sur le même conteneur,
/// dans toutes les fenêtres (`generation` alimente leur `revision`).
///
/// ## Le conteneur de réserve
/// `container` est non optionnel parce que beaucoup d'appelants (tests,
/// favoris) le lisent tel quel. Quand le stockage est indisponible il renvoie
/// un conteneur en mémoire VIDE qui n'est jamais lu ni écrit : les stores
/// passent par `context`, qui vaut `nil` dans cet état.
@Observable
@MainActor
final class TrivaStorage {
    /// État du stockage. `reason` est un détail technique pour les logs et les
    /// tests, jamais pour l'écran.
    enum State: Equatable, Sendable {
        case ready
        case unavailable(reason: String)
    }

    /// Titre de l'écran d'erreur. **À VALIDER PAR BEN.**
    static let unavailableTitle = "Impossible d'ouvrir tes conversations enregistrées"

    /// Sous-titre de l'écran d'erreur : dit que la recherche reste possible et
    /// que rien n'est enregistré. **À VALIDER PAR BEN.**
    static let unavailableDetail =
        "Tes recherches restent possibles, mais rien n'est enregistré tant que ce problème dure."

    /// Pauses, en millisecondes, entre les tentatives automatiques d'ouverture :
    /// quatre essais en moins d'une seconde au total.
    static let defaultRetryDelaysMilliseconds = [80, 200, 500]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "TrivaStorage"
    )

    /// Conteneur jamais lu ni écrit, voir « Le conteneur de réserve ».
    private static let placeholderContainer: ModelContainer = {
        do {
            return try TrivaModelContainer.makeInMemory()
        } catch {
            // Un conteneur en mémoire qui échoue trahit un schéma invalide : un
            // bug de développement, jamais une entrée utilisateur.
            preconditionFailure("Schéma SwiftData invalide : conteneur de réserve impossible. \(error)")
        }
    }()

    private(set) var state: State

    /// Incrémenté à chaque `retry()` réussi : les stores l'ajoutent à leur
    /// `revision`, ce qui recharge la Bibliothèque et les Favoris de toutes les
    /// fenêtres.
    private(set) var generation = 0

    private var opened: ModelContainer?
    private let opener: (@MainActor () throws -> ModelContainer)?
    private let retryDelaysMilliseconds: [Int]
    private let pause: @MainActor (Int) -> Void
    private let dataDeleter: @MainActor (ModelContainer) throws -> Void

    /// Stockage déjà ouvert : tests, aperçus, et les `init(container:)` des
    /// stores. Ne peut pas être indisponible, donc `retry()` n'a rien à faire.
    init(container: ModelContainer) {
        self.state = .ready
        self.opener = nil
        self.retryDelaysMilliseconds = []
        self.pause = { _ in }
        self.dataDeleter = { $0.deleteAllData() }
        adopt(container)
    }

    /// Stockage ouvert par `opener`, avec des tentatives automatiques :
    /// `retryDelaysMilliseconds.count + 1` essais, séparés par ces pauses.
    /// Les pauses bloquent le fil appelant ; elles n'ont lieu que si l'ouverture
    /// échoue, donc jamais sur le chemin normal.
    ///
    /// - Parameters:
    ///   - pause: attente entre deux essais (millisecondes), injectable pour
    ///     que les tests n'attendent rien.
    ///   - dataDeleter: effacement complet du conteneur ; `deleteAllData()` en
    ///     production, remplaçable par les tests pour simuler son échec.
    init(
        opener: @escaping @MainActor () throws -> ModelContainer,
        retryDelaysMilliseconds: [Int] = TrivaStorage.defaultRetryDelaysMilliseconds,
        pause: @escaping @MainActor (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) },
        dataDeleter: @escaping @MainActor (ModelContainer) throws -> Void = { $0.deleteAllData() }
    ) {
        self.opener = opener
        self.dataDeleter = dataDeleter
        self.retryDelaysMilliseconds = retryDelaysMilliseconds
        self.pause = pause
        self.state = .unavailable(reason: "")
        openWithRetries()
    }

    /// `retryDelaysMilliseconds.count + 1` essais d'ouverture, séparés par les pauses.
    private func openWithRetries() {
        for attempt in 0...retryDelaysMilliseconds.count {
            if attemptOpening() { return }
            if attempt < retryDelaysMilliseconds.count {
                pause(retryDelaysMilliseconds[attempt])
            }
        }
    }

    var isAvailable: Bool { state == .ready }

    /// Conteneur ouvert, ou le conteneur de réserve vide si indisponible.
    var container: ModelContainer { opened ?? Self.placeholderContainer }

    /// Contexte unique de l'app, `nil` tant que le stockage est indisponible :
    /// c'est ce `nil` qui fait refuser aux stores toute lecture et écriture.
    var context: ModelContext? { opened?.mainContext }

    /// Retente l'ouverture (bouton « Réessayer »). Un seul essai, sans pause :
    /// l'utilisateur relance autant de fois qu'il veut. Renvoie `true` si le
    /// stockage est disponible à l'issue.
    @discardableResult
    func retry() -> Bool {
        guard opener != nil, !isAvailable else { return isAvailable }
        if attemptOpening() {
            generation += 1
        }
        return isAvailable
    }

    // MARK: - Effacement complet

    /// Pourquoi `eraseAllData()` n'a pas (ou pas entièrement) abouti.
    enum EraseError: Error, Equatable, Sendable {
        /// Conteneur injecté (tests, aperçus) : il n'y a pas d'ouvreur pour
        /// recréer une base neuve ; l'appelant efface objet par objet.
        case reopeningNotSupported
        /// Base déjà indisponible : il n'y a rien à effacer proprement.
        case storageUnavailable
        /// `ModelContainer.deleteAllData()` a échoué. La base a été rouverte
        /// (si possible) et peut contenir encore des données.
        case deleteFailed(String)
    }

    /// Efface TOUTE la base d'un coup par `ModelContainer.deleteAllData()`
    /// (décision de Ben, 2026-11-14), puis recrée un conteneur neuf sur le
    /// disque et rebranche dessus tous les consommateurs.
    ///
    /// ## Pourquoi recréer le conteneur
    /// Mesuré (banc `DeleteAllDataBenchTests`, mission C2) : `deleteAllData()`
    /// efface immédiatement et complètement (aucune trace dans `.store`, `-wal`,
    /// `-shm`), mais le conteneur qui a servi ne sait plus identifier son
    /// magasin : toute écriture ultérieure plante (« Failed to identify a store
    /// that can hold instances of … »). On le relâche donc AVANT d'en ouvrir un
    /// neuf avec le même ouvreur (mêmes réessais qu'au lancement).
    ///
    /// ## Rebranchement
    /// `ChatHistoryStore` et `FavoritesStore` relisent `context` à chaque
    /// opération (ils n'en gardent aucun) : ils passent seuls sur le nouveau
    /// conteneur. `generation` est incrémenté, donc leur `revision` aussi, ce
    /// qui recharge Bibliothèque, Favoris et vide le fil ouvert. À l'appelant
    /// d'avoir arrêté toute génération en cours avant (`ChatViewModel.stopAndWait`).
    ///
    /// ## Échecs
    /// - `deleteAllData()` échoue : la base est quand même rouverte, `deleteFailed`
    ///   est levée, l'appelant retombe sur la suppression objet par objet.
    /// - la réouverture échoue après un effacement réussi : la base est vide
    ///   sur disque, `state` vaut `.unavailable` (les écrans le disent, avec
    ///   « Réessayer »), et `eraseAllData()` ne lève RIEN : les données SONT
    ///   effacées, déclarer l'inverse serait faux.
    func eraseAllData() throws(EraseError) {
        guard opener != nil else { throw .reopeningNotSupported }
        guard let current = opened else { throw .storageUnavailable }
        var deletionError: String?
        do {
            try dataDeleter(current)
        } catch {
            Self.logger.error("deleteAllData a échoué : \(String(describing: error), privacy: .private)")
            deletionError = String(describing: error)
        }
        // Relâché avant la réouverture : le conteneur d'avant n'est plus utilisable.
        opened = nil
        state = .unavailable(reason: "réouverture après effacement")
        openWithRetries()
        generation += 1
        if let deletionError { throw .deleteFailed(deletionError) }
    }

    private func attemptOpening() -> Bool {
        guard let opener else { return false }
        do {
            adopt(try opener())
            return true
        } catch {
            let reason = (error as? TrivaModelContainerError)?.diagnosticDescription ?? String(describing: error)
            Self.logger.error("Base locale illisible : \(reason, privacy: .private)")
            state = .unavailable(reason: reason)
            return false
        }
    }

    private func adopt(_ container: ModelContainer) {
        opened = container
        // Chaque méthode des stores sauvegarde explicitement (politique
        // d'écriture de `ChatHistoryStore`) : l'enregistrement automatique
        // ferait valider les écritures à des moments choisis par le runtime.
        container.mainContext.autosaveEnabled = false
        state = .ready
    }
}
