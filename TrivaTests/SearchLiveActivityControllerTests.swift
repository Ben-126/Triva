//
//  SearchLiveActivityControllerTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission D) : le contrôleur d'activité en direct, avec un FAUX client (aucun ActivityKit, aucun
//  simulateur) : séquence démarrage / mises à jour / fin, réglage éteint, séance sans fenêtre, arrière-plan.
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class FakeLiveActivityClient: LiveActivityClient {
    enum Call: Equatable {
        case start(question: String, conversationID: UUID?, state: SearchActivityState, staleDate: Date, id: String)
        case update(id: String, state: SearchActivityState, staleDate: Date)
        case end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy)
        case endAll
        case dismiss(id: String)
    }

    var areActivitiesEnabled = true
    var startError: (any Error)?
    /// Retarde les mises à jour de la 1re étape : l'ordre doit rester celui des événements.
    var slowFirstUpdate = false
    private(set) var calls: [Call] = []
    private var counter = 0
    private var updateCount = 0

    func start(attributes: SearchActivityAttributes, state: SearchActivityState, staleDate: Date) throws -> String {
        if let startError { throw startError }
        counter += 1
        let id = "activity-\(counter)"
        calls.append(.start(question: attributes.question, conversationID: attributes.conversationID, state: state, staleDate: staleDate, id: id))
        return id
    }

    func update(id: String, state: SearchActivityState, staleDate: Date) async {
        updateCount += 1
        if slowFirstUpdate, updateCount == 1 { try? await Task.sleep(for: .milliseconds(40)) }
        calls.append(.update(id: id, state: state, staleDate: staleDate))
    }

    func end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy) async {
        calls.append(.end(id: id, state: state, policy: policy))
    }

    func endAll() async { calls.append(.endAll) }

    /// Activités « encore à l'écran » que le test choisit (id, conversation).
    var open: [OpenLiveActivity] = []
    func openActivities() -> [OpenLiveActivity] { open }
    func dismiss(id: String) async { calls.append(.dismiss(id: id)) }

    var starts: [Call] { calls.filter { if case .start = $0 { true } else { false } } }
    var updates: [Call] { calls.filter { if case .update = $0 { true } else { false } } }
    var ends: [Call] { calls.filter { if case .end = $0 { true } else { false } } }
}

@MainActor
private final class FakeBackgroundKeeper: BackgroundRunKeeping {
    private(set) var begun: [String] = []
    private(set) var ended: [BackgroundRunToken] = []
    private(set) var expiryHandlers: [@MainActor @Sendable () -> Void] = []
    var refuses = false
    private var next = 100

    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken? {
        guard !refuses else { return nil }
        begun.append(name)
        expiryHandlers.append(onExpire)
        next += 1
        return BackgroundRunToken(rawValue: next)
    }

    func end(_ token: BackgroundRunToken) { ended.append(token) }
}

@MainActor
private final class Env {
    var isActive = true
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
@Suite("Activité en direct : contrôleur")
struct SearchLiveActivityControllerTests {
    private let client = FakeLiveActivityClient()
    private let keeper = FakeBackgroundKeeper()
    private let env = Env()
    private let defaults: UserDefaults
    private let answer = UUID()
    private let conversation = UUID()

    init() {
        let suite = "SearchLiveActivityControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController(heartbeat: Duration = .seconds(3_600)) -> SearchLiveActivityController {
        let env = env
        return SearchLiveActivityController(
            client: client,
            keeper: keeper,
            preferences: SystemIntegrationPreferences(defaults: defaults),
            isAppActive: { env.isActive },
            now: { env.now },
            heartbeat: heartbeat
        )
    }

    private func started(_ question: String = "Capitale de la France ?") -> SearchProgressEvent {
        .started(question: question, conversationID: conversation)
    }

    // MARK: Séquence normale

    @Test("Séquence complète : démarrage, lecture, rédaction, fin immédiate quand l'app est active")
    func fullSequenceInForeground() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.sources(count: 3), answerID: answer)
        controller.searchProgress(.writing, answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        let stale = env.now.addingTimeInterval(SearchLiveActivityController.staleInterval)
        #expect(client.calls == [
            .start(question: "Capitale de la France ?", conversationID: conversation, state: .initial, staleDate: stale, id: "activity-1"),
            .update(id: "activity-1", state: SearchActivityState(stage: .reading, sourceCount: 3), staleDate: stale),
            .update(id: "activity-1", state: SearchActivityState(stage: .writing, sourceCount: 3), staleDate: stale),
            .end(id: "activity-1", state: SearchActivityState(stage: .ready, sourceCount: 3), policy: .immediate),
        ])
    }

    @Test("Réponse prête alors que l'app est en arrière-plan : l'activité reste 30 minutes")
    func readyInBackground() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        env.isActive = false
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        let expected = env.now.addingTimeInterval(SearchLiveActivityController.readyLinger)
        #expect(SearchLiveActivityController.readyLinger == 1_800)
        #expect(client.ends == [.end(id: "activity-1", state: SearchActivityState(stage: .ready, sourceCount: 0), policy: .after(expected))])
    }

    @Test("Recherche interrompue ou échouée : l'activité reste 5 minutes", arguments: [
        SearchProgressEvent.interrupted, .failed,
    ])
    func interruptedOrFailed(event: SearchProgressEvent) async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(event, answerID: answer)
        await controller.settle()

        let expected = env.now.addingTimeInterval(SearchLiveActivityController.failureLinger)
        #expect(SearchLiveActivityController.failureLinger == 300)
        let stage: SearchActivityStage = event == .interrupted ? .interrupted : .failed
        #expect(client.ends == [.end(id: "activity-1", state: SearchActivityState(stage: stage, sourceCount: 0), policy: .after(expected))])
    }

    @Test("Chaque mise à jour repousse la date de péremption de 2 minutes")
    func staleDateIsPushedBack() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        env.now = env.now.addingTimeInterval(45)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        await controller.settle()

        let stale = env.now.addingTimeInterval(120)
        #expect(client.updates == [.update(id: "activity-1", state: SearchActivityState(stage: .reading, sourceCount: 2), staleDate: stale)])
    }

    @Test("Les mises à jour partent dans l'ordre des événements, même si la première est lente")
    func updatesKeepTheirOrder() async {
        client.slowFirstUpdate = true
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        controller.searchProgress(.writing, answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        let stages: [SearchActivityStage] = client.calls.compactMap {
            switch $0 {
            case .update(_, let state, _), .end(_, let state, _): state.stage
            default: nil
            }
        }
        #expect(stages == [.reading, .writing, .ready])
    }

    @Test("Un événement qui ne change rien ne produit aucune mise à jour")
    func unchangedStateIsNotSent() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.searching, answerID: answer)
        controller.searchProgress(.sources(count: 0), answerID: answer)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        await controller.settle()

        #expect(client.updates.count == 1)
    }

    // MARK: Quand il n'y a pas d'activité

    @Test("Réglage éteint : aucune activité n'est démarrée")
    func settingOff() async {
        SystemIntegrationPreferences(defaults: defaults).isLiveActivityEnabled = false
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.calls.isEmpty)
        #expect(keeper.begun.isEmpty)
    }

    @Test("Par défaut (réglage jamais touché), l'activité est allumée")
    func defaultIsOn() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        await controller.settle()

        #expect(client.starts.count == 1)
    }

    @Test("Activités coupées dans les Réglages du système : rien n'est démarré")
    func disabledBySystem() async {
        client.areActivitiesEnabled = false
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        await controller.settle()

        #expect(client.calls.isEmpty)
    }

    @Test("App pas au premier plan au début de l'échange : rien n'est démarré")
    func notStartedInBackground() async {
        env.isActive = false
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.calls.isEmpty)
    }

    @Test("Séance sans fenêtre : des événements d'un échange jamais démarré sont ignorés")
    func unknownExchangeIsIgnored() async {
        let controller = makeController()
        controller.searchProgress(.sources(count: 2), answerID: answer)
        controller.searchProgress(.writing, answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.calls.isEmpty)
        #expect(keeper.begun.isEmpty)
    }

    @Test("Le système refuse de démarrer : aucune trace, aucune tâche d'arrière-plan, la suite est ignorée")
    func startFailure() async {
        client.startError = LiveActivityUnavailableError()
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.calls.isEmpty)
        #expect(keeper.begun.isEmpty)
    }

    // MARK: Un échange à la fois, une activité par échange

    @Test("Un nouvel échange pour la même réponse termine l'ancienne activité tout de suite")
    func restartedExchangeReplacesTheOldActivity() async {
        let controller = makeController()
        controller.searchProgress(started("Première"), answerID: answer)
        controller.searchProgress(started("Seconde"), answerID: answer)
        await controller.settle()

        #expect(client.starts.count == 2)
        #expect(client.ends == [.end(id: "activity-1", state: .initial, policy: .immediate)])
        #expect(keeper.ended.count == 1)
    }

    @Test("Deux fenêtres, deux échanges : deux activités indépendantes")
    func twoExchanges() async {
        let other = UUID()
        let controller = makeController()
        controller.searchProgress(started("A"), answerID: answer)
        controller.searchProgress(started("B"), answerID: other)
        controller.searchProgress(.completed, answerID: other)
        controller.searchProgress(.sources(count: 1), answerID: answer)
        await controller.settle()

        #expect(client.starts.count == 2)
        #expect(client.ends.count == 1)
        #expect(client.updates == [.update(id: "activity-1", state: SearchActivityState(stage: .reading, sourceCount: 1), staleDate: env.now.addingTimeInterval(120))])
    }

    // MARK: Arrière-plan

    @Test("Une tâche d'arrière-plan par échange, terminée à la fin")
    func backgroundTaskBalanced() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        #expect(keeper.begun.count == 1)
        #expect(keeper.ended.isEmpty)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()
        #expect(keeper.ended.count == 1)
    }

    @Test("Le système refuse du temps d'arrière-plan : l'activité démarre quand même")
    func keeperRefuses() async {
        keeper.refuses = true
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.starts.count == 1)
        #expect(client.ends.count == 1)
        #expect(keeper.ended.isEmpty)
    }

    @Test("Temps d'arrière-plan écoulé : « Recherche interrompue » pendant 5 minutes, la suite est ignorée")
    func backgroundTimeExpires() async throws {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.sources(count: 2), answerID: answer)
        env.isActive = false
        let expire = try #require(keeper.expiryHandlers.first)
        expire()
        controller.searchProgress(.writing, answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        let expected = env.now.addingTimeInterval(SearchLiveActivityController.failureLinger)
        #expect(client.ends == [.end(id: "activity-1", state: SearchActivityState(stage: .interrupted, sourceCount: 2), policy: .after(expected))])
        #expect(client.updates.count == 1)
        #expect(keeper.ended.count == 1)
    }

    // MARK: Battement, orphelines, effacement

    @Test("Pendant une longue rédaction, un battement repousse la date de péremption")
    func heartbeatRefreshesStaleDate() async throws {
        let controller = makeController(heartbeat: .milliseconds(5))
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.writing, answerID: answer)
        for _ in 0..<400 where client.updates.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        let writingUpdates = client.updates.filter {
            if case .update(_, let state, _) = $0 { state.stage == .writing } else { false }
        }
        #expect(writingUpdates.count >= 2)
        #expect(client.ends.count == 1)
    }

    @Test("Après la fin, plus aucun battement")
    func heartbeatStopsAtTheEnd() async throws {
        let controller = makeController(heartbeat: .milliseconds(5))
        controller.searchProgress(started(), answerID: answer)
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()
        let before = client.calls.count
        try await Task.sleep(for: .milliseconds(60))
        await controller.settle()

        #expect(client.calls.count == before)
    }

    @Test("Au lancement, les activités orphelines sont closes")
    func orphansAreClosed() async {
        let controller = makeController()
        await controller.closeOrphans()

        #expect(client.calls == [.endAll])
    }

    @Test("« Tout effacer » ferme toutes les activités et oublie les échanges en cours")
    func eraseEndsEverything() async {
        let controller = makeController()
        controller.searchProgress(started(), answerID: answer)
        await controller.endAll()
        controller.searchProgress(.completed, answerID: answer)
        await controller.settle()

        #expect(client.calls.last == .endAll)
        #expect(client.ends.isEmpty)
        #expect(keeper.ended.count == 1)
    }

    @Test("Le client « indisponible » (Mac) n'ouvre jamais d'activité")
    func unavailableClient() async {
        let unavailable = UnavailableLiveActivityClient()
        #expect(unavailable.areActivitiesEnabled == false)
        #expect(throws: LiveActivityUnavailableError.self) {
            try unavailable.start(attributes: SearchActivityAttributes(question: "q", conversationID: nil), state: .initial, staleDate: .now)
        }
    }
}
