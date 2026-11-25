//
//  SearchLiveActivityController.swift
//  Triva
//
//  Chantier 2.1 (mission D) : l'activité en direct d'une recherche (écran verrouillé, Dynamic Island), sur iPhone et
//  iPad. Ce contrôleur écoute l'avancement d'un échange (`SearchProgressObserving`) et le traduit en activité, par
//  le seul `LiveActivityClient` : il ne connaît pas ActivityKit.
//
//  Règles (spec 2.1, §4.5, et décisions de Ben du 2026-11-24) :
//  - une activité par échange, démarrée au début de l'échange si l'app est au premier plan, si le système autorise
//    les activités et si le réglage « Activité en direct pendant une recherche » est allumé (allumé par défaut) ;
//  - mises à jour LOCALES seulement (pas de serveur, pas de push) : la date de péremption est repoussée de 2 minutes à
//    chaque mise à jour, et un battement la repousse pendant une longue rédaction ; passée la date, l'écran affiche
//    « Recherche interrompue » (`SearchActivityState.displayed(isStale:)`) ;
//  - quelques secondes d'arrière-plan sont demandées au système pendant l'échange ; si elles expirent, l'activité
//    finit « interrompue » ;
//  - fin : réponse prête et app active, l'activité disparaît tout de suite ; réponse prête alors que l'app est en
//    arrière-plan, elle reste 30 minutes ; interrompue ou échouée, 5 minutes ;
//  - une séance sans fenêtre (Siri, Raccourcis) n'a pas d'observateur : le système affiche déjà sa progression.
//
//  Les appels au client partent dans l'ordre des événements (une seule file), même si l'un d'eux est lent.
//

import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

@MainActor
final class SearchLiveActivityController: SearchProgressObserving {
    /// Le contrôleur de l'app. Sur iPhone et iPad (hors tests) : ActivityKit pour de vrai ; ailleurs, jamais d'activité.
    static let shared = SearchLiveActivityController.live()

    static func live() -> SearchLiveActivityController {
        #if os(iOS)
        if !TrivaTestHost.isHostingUnitTests() {
            return SearchLiveActivityController(
                client: ActivityKitLiveActivityClient(),
                keeper: UIKitBackgroundRunKeeper(),
                isAppActive: { UIApplication.shared.applicationState == .active }
            )
        }
        #endif
        return SearchLiveActivityController(client: UnavailableLiveActivityClient(), keeper: NoBackgroundRunKeeper(), isAppActive: { false })
    }

    static let staleInterval: TimeInterval = 120
    static let readyLinger: TimeInterval = 30 * 60
    static let failureLinger: TimeInterval = 5 * 60

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Triva", category: "SearchLiveActivity")

    /// Une activité ouverte. Le battement est annulé à la fin.
    private struct Entry {
        let activityID: String
        var state: SearchActivityState
        let token: BackgroundRunToken?
        let heartbeat: Task<Void, Never>?
    }

    private let client: any LiveActivityClient
    private let keeper: any BackgroundRunKeeping
    private let preferences: SystemIntegrationPreferences
    private let isAppActive: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let heartbeatInterval: Duration

    /// Échanges en cours, par identifiant de la réponse (`ChatViewModel.Exchange.answerID`).
    private var entries: [UUID: Entry] = [:]
    /// Dernière opération envoyée au client : chaque nouvelle attend la précédente, ce qui garde l'ordre.
    private var lastOperation: Task<Void, Never>?

    init(
        client: any LiveActivityClient,
        keeper: any BackgroundRunKeeping,
        preferences: SystemIntegrationPreferences = SystemIntegrationPreferences(),
        isAppActive: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        heartbeat: Duration = .seconds(60)
    ) {
        self.client = client
        self.keeper = keeper
        self.preferences = preferences
        self.isAppActive = isAppActive
        self.now = now
        self.heartbeatInterval = heartbeat
    }

    // MARK: SearchProgressObserving

    func searchProgress(_ event: SearchProgressEvent, answerID: UUID) {
        if case .started(let question, let conversationID) = event {
            begin(question: question, conversationID: conversationID, answerID: answerID)
            return
        }
        // Un échange jamais démarré (réglage éteint, app en arrière-plan, système qui refuse) : rien à suivre.
        guard var entry = entries[answerID] else { return }
        let next = SearchActivityStage.next(entry.state, event: event)
        guard next != entry.state else { return }
        entry.state = next
        if next.stage.isTerminal {
            finish(answerID: answerID, entry: entry, policy: endPolicy(for: next.stage))
        } else {
            entries[answerID] = entry
            enqueueUpdate(of: entry)
        }
    }

    // MARK: Pour les tests, le lancement et « Tout effacer »

    /// Attend que tout ce qui a été demandé au client soit fait.
    func settle() async {
        await lastOperation?.value
    }

    /// Au lancement : une activité laissée par un lancement précédent n'a plus personne pour la mettre à jour.
    func closeOrphans() async {
        let client = client
        enqueue { await client.endAll() }
        await settle()
    }

    /// Les activités terminées mais encore à l'écran dont la conversation n'existe plus (supprimée) : retirées tout de
    /// suite, la question n'a pas à rester sur l'écran verrouillé pendant 30 minutes. Les activités d'un échange EN
    /// COURS ne sont pas touchées (sa conversation peut ne pas être encore enregistrée).
    ///
    /// - Parameter exists: dit si une conversation existe ; une lecture qui échoue doit répondre `true`.
    func endActivities(whereConversationIsMissing exists: @MainActor (UUID) -> Bool) async {
        let inFlight = Set(entries.values.map(\.activityID))
        let missing = client.openActivities().filter { activity in
            guard !inFlight.contains(activity.id), let conversationID = activity.conversationID else { return false }
            return !exists(conversationID)
        }
        guard !missing.isEmpty else { return }
        let client = client
        for activity in missing {
            let id = activity.id
            enqueue { await client.dismiss(id: id) }
        }
        await settle()
    }

    /// « Tout effacer » : plus aucune activité, plus aucun échange suivi, plus aucune tâche d'arrière-plan.
    func endAll() async {
        for entry in entries.values {
            entry.heartbeat?.cancel()
            if let token = entry.token { keeper.end(token) }
        }
        entries.removeAll()
        await closeOrphans()
    }

    // MARK: Démarrage

    private func begin(question: String, conversationID: UUID?, answerID: UUID) {
        // Le même message qu'on relance (Rapide, hors connexion) : l'ancienne activité s'efface d'abord.
        if let old = entries[answerID] {
            finish(answerID: answerID, entry: old, policy: .immediate)
        }
        guard preferences.isLiveActivityEnabled, client.areActivitiesEnabled, isAppActive() else { return }

        let attributes = SearchActivityAttributes(question: question, conversationID: conversationID)
        let activityID: String
        do {
            activityID = try client.start(attributes: attributes, state: .initial, staleDate: staleDate())
        } catch {
            // Refus du système (limite d'activités, réglage coupé entre-temps) : la recherche continue sans activité.
            Self.logger.info("Activité en direct non démarrée : \(String(describing: error), privacy: .public)")
            return
        }
        let token = keeper.begin(name: "Triva : recherche en cours") { [weak self] in
            self?.backgroundTimeExpired(answerID: answerID)
        }
        entries[answerID] = Entry(
            activityID: activityID,
            state: .initial,
            token: token,
            heartbeat: startHeartbeat(answerID: answerID)
        )
    }

    // MARK: Mises à jour et fin

    private func enqueueUpdate(of entry: Entry) {
        let client = client
        let (id, state, stale) = (entry.activityID, entry.state, staleDate())
        enqueue { await client.update(id: id, state: state, staleDate: stale) }
    }

    private func finish(answerID: UUID, entry: Entry, policy: LiveActivityEndPolicy) {
        entries[answerID] = nil
        entry.heartbeat?.cancel()
        let client = client
        let keeper = keeper
        let (id, state, token) = (entry.activityID, entry.state, entry.token)
        enqueue {
            await client.end(id: id, state: state, policy: policy)
            if let token { keeper.end(token) }
        }
    }

    private func endPolicy(for stage: SearchActivityStage) -> LiveActivityEndPolicy {
        switch stage {
        case .ready:
            isAppActive() ? .immediate : .after(now().addingTimeInterval(Self.readyLinger))
        default:
            .after(now().addingTimeInterval(Self.failureLinger))
        }
    }

    /// Le système va suspendre l'app : la recherche n'avance plus, l'activité le dit au lieu de mentir.
    private func backgroundTimeExpired(answerID: UUID) {
        searchProgress(.interrupted, answerID: answerID)
    }

    private func staleDate() -> Date {
        now().addingTimeInterval(Self.staleInterval)
    }

    // MARK: Battement

    /// Pendant une longue rédaction (modèle local), aucune étape ne change pendant plus de 2 minutes : sans battement,
    /// l'écran déclarerait la recherche interrompue alors qu'elle écrit encore.
    private func startHeartbeat(answerID: UUID) -> Task<Void, Never> {
        let interval = heartbeatInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.refreshStaleDate(answerID: answerID)
            }
        }
    }

    private func refreshStaleDate(answerID: UUID) {
        guard let entry = entries[answerID], !entry.state.stage.isTerminal else { return }
        enqueueUpdate(of: entry)
    }

    // MARK: File d'opérations

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            await operation()
        }
    }
}
