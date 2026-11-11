//
//  ConnectivityMonitor.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Network
import Observation

/// Ce que le système sait de la connexion à un instant donné (tâche 1.16, mode hors connexion).
///
/// TROIS états, pas deux, exprès : « je ne sais pas encore » n'est pas « hors connexion ». Avant la
/// première mesure du système (quelques millisecondes après le lancement), et pour un chemin qui
/// « nécessite une connexion » (`NWPath.Status.requiresConnection` : VPN à la demande, radio coupée
/// mais activable), conclure « hors connexion » bloquerait une recherche qui aurait pu aboutir.
/// Seul `.offline` désactive quoi que ce soit dans l'app ; `.unknown` se comporte comme `.online`.
nonisolated enum ConnectivityStatus: Sendable, Equatable {
    case unknown
    case online
    case offline

    /// `.satisfied` -> en ligne ; `.unsatisfied` -> hors connexion (mode Avion, aucun réseau) ; le
    /// reste -> inconnu. Un chemin « satisfait » n'est PAS une garantie d'accès à Internet (portail
    /// captif, Wi-Fi sans route) : les erreurs réseau (`URLError.indicatesNoConnection`,
    /// `WebSearchChainError.isDeviceOffline`) restent donc gérées partout, ce moniteur n'est qu'un
    /// raccourci pour ne pas tenter dans le vide quand le système sait déjà qu'il n'y a rien.
    init(_ status: NWPath.Status) {
        switch status {
        case .satisfied: self = .online
        case .unsatisfied: self = .offline
        case .requiresConnection: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

/// Source des états de connexion, injectable : le vrai moniteur système en production
/// (`NWPathConnectivitySource`), une source pilotée à la main dans les tests (aucun test ne dépend
/// de la connexion réelle de la machine).
nonisolated protocol ConnectivitySource: Sendable {
    /// États successifs ; le premier est l'état courant. Le flux ne se termine jamais de lui-même,
    /// seule l'annulation de la tâche qui l'itère l'arrête.
    func updates() -> AsyncStream<ConnectivityStatus>
}

/// `NWPathMonitor` du framework Network (Apple, aucune dépendance). Le moniteur vit le temps du flux :
/// annuler la tâche qui l'itère l'annule (`onTermination`).
nonisolated struct NWPathConnectivitySource: ConnectivitySource {
    func updates() -> AsyncStream<ConnectivityStatus> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(ConnectivityStatus(path.status))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "Triva.ConnectivityMonitor", qos: .utility))
        }
    }
}

/// Source figée : l'état donné, une seule fois. Sert d'hôte de tests (`ConnectivityMonitor.shared`
/// hors production) et de base aux previews.
nonisolated struct FixedConnectivitySource: ConnectivitySource {
    let status: ConnectivityStatus

    func updates() -> AsyncStream<ConnectivityStatus> {
        AsyncStream { continuation in
            continuation.yield(status)
            // Pas de `finish()` : le contrat dit que le flux ne se termine pas de lui-même.
        }
    }
}

/// État de connexion de l'app, observable : l'interface (bannière « Hors connexion », bouton de
/// relance, Découvrir) et le ViewModel du chat le lisent, l'entretien SearXNG le consulte avant de
/// télécharger l'annuaire ou de sonder une instance.
///
/// Un seul exemplaire pour toute l'app (`shared`) : plusieurs `NWPathMonitor` ne se contredisent
/// pas, mais ils coûteraient autant de files système pour la même information.
///
/// Sous les tests unitaires (l'app sert d'hôte, voir `TrivaTestHost`), `shared` est figé sur
/// `.unknown` : jamais de vrai moniteur réseau dans un test, et jamais un test qui change de
/// résultat selon le Wi-Fi de la machine qui le lance.
@Observable
@MainActor
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor(
        source: TrivaTestHost.isHostingUnitTests()
            ? FixedConnectivitySource(status: .unknown)
            : NWPathConnectivitySource()
    )

    /// Dernier état connu. `.unknown` jusqu'à la première mesure du système.
    private(set) var status: ConnectivityStatus

    /// Vrai SEULEMENT si le système dit qu'il n'y a pas de chemin réseau. `.unknown` n'est pas
    /// « hors connexion » (voir `ConnectivityStatus`).
    var isOffline: Bool { status == .offline }

    @ObservationIgnored private let source: any ConnectivitySource
    @ObservationIgnored private var listening: Task<Void, Never>?

    /// - Parameters:
    ///   - source: d'où viennent les états.
    ///   - initialStatus: état avant la première mesure.
    ///   - startsImmediately: `false` pour un test qui veut démarrer à la main.
    init(
        source: any ConnectivitySource,
        initialStatus: ConnectivityStatus = .unknown,
        startsImmediately: Bool = true
    ) {
        self.source = source
        self.status = initialStatus
        if startsImmediately { start() }
    }

    /// Commence à écouter la source. Sans effet si l'écoute est déjà en cours.
    func start() {
        guard listening == nil else { return }
        let updates = source.updates()
        listening = Task { [weak self] in
            for await next in updates {
                // Après `stop()`, un état déjà en route ne doit plus être appliqué.
                guard let self, !Task.isCancelled else { return }
                if self.status != next { self.status = next }
            }
        }
    }

    /// Arrête l'écoute (annule le moniteur système). L'état courant est conservé.
    func stop() {
        listening?.cancel()
        listening = nil
    }

    isolated deinit {
        listening?.cancel()
    }
}
